import SwiftUI
import AppKit
import AgentCore
import AgentUI
import AgentProtocol
import ClaudeCode
import AgentRemoteControl

/// macOS app entry point. Owns one `AgentEngine` per workspace, a single
/// `EngineViewModel` bound to it, and an in-process `RemoteControlServer`
/// so paired mobile clients can drive the same engine over Wi-Fi.
@main
struct CodemixerApp: App {

    @State private var bootstrap = Bootstrap()

    init() {
        // Reap zombie children (PTY workers, openssl, git) early.
        ChildReaper.shared.install()
    }

    var body: some Scene {
        WindowGroup {
            RootView(bootstrap: bootstrap)
                .frame(minWidth: 1024, minHeight: 640)
                .task { await bootstrap.start() }
        }
        .windowToolbarStyle(.unifiedCompact)
        .commands {
            CommandGroup(replacing: .newItem) {
                Button("Open Project…") { bootstrap.showProjectPicker = true }
                    .keyboardShortcut("o", modifiers: .command)
                Button("Cancel Turn") { bootstrap.viewModel?.send(.cancelCurrentTurn) }
                    .keyboardShortcut(".", modifiers: .command)
                    .disabled(bootstrap.viewModel?.canCancel != true)
            }
            CommandGroup(after: .saveItem) {
                Button("Export as Markdown…") { bootstrap.exportSession(as: .markdown) }
                    .keyboardShortcut("e", modifiers: [.command, .shift])
                Button("Export as JSONL…") { bootstrap.exportSession(as: .jsonl) }
                Button("Export as HTML…") { bootstrap.exportSession(as: .html) }
            }
            CommandGroup(replacing: .help) {
                Button("Show Event Log") { bootstrap.showEventLog = true }
            }
        }
    }
}

@MainActor
@Observable
final class Bootstrap {
    var viewModel: EngineViewModel?
    var workspace: URL?
    var remoteFingerprint: String?
    var remoteHost: RemoteControlServer.BindHost = .loopback
    var showProjectPicker: Bool = false
    var showSettings: Bool = false
    var showDebugTerminal: Bool = false
    var showEventLog: Bool = false
    var authURL: URL?
    var recents: [SessionStore.ProjectRecord] = []
    var startupError: String?
    /// Non-nil when the last `openWorkspace` failed with `binaryNotFound`.
    var installHint: String?

    let voice = VoiceInputService()
    let tts = TTSService()

    private var engine: AgentEngine?
    private var remoteClient: RemoteEngineClient?
    private var eventBus: MulticastEventBus?
    private var remoteRuntime: RemoteRuntimeCoordinator?
    private var pairing: PairingService?
    private let launchAgentInstaller = LaunchAgentInstaller()

    var bus: MulticastEventBus? { eventBus }

    var debugTerminalSnapshotText: (@Sendable () async -> String)? {
        guard let engine else { return nil }
        return { await engine.terminalSnapshotText() }
    }

    func start() async {
        guard viewModel == nil else { return }
        if await startDaemonBackedUIIfRequested() {
            return
        }

        let engine = AgentEngine()
        self.engine = engine
        await engine.bootstrap()

        let adapter = ClaudeAdapter()
        await AdapterRegistry.shared.register(adapter)

        let model = EngineViewModel(engine: engine, bus: engine.bus)
        viewModel = model
        eventBus = engine.bus
        recents = await engine.sessions.recents()

        // Session navigator wiring (agent-agnostic): the lister resolves the
        // adapter via the registry so AgentUI never imports a concrete adapter.
        let projectsStore = WorkspaceProjectsStore(environment: Seams.live.environment,
                                                   fileSystem: Seams.live.fileSystem)
        await projectsStore.load()
        model.workspaceProjects = projectsStore
        let adapterID = adapter.id
        model.sessionLister = { url in
            guard let resolved = await AdapterRegistry.shared.adapter(for: adapterID) else { return [] }
            return await resolved.listResumableSessions(workspace: url)
        }
        model.supportsResumableSessions = adapter.capabilities.contains(.resumableSessions)
        model.sidebarVisible = await engine.prefs.state().appearance.sidebarVisible
        model.hydrate(from: await engine.prefs.state())

        startTTSSubscription(bus: engine.bus)

        if recents.isEmpty {
            showProjectPicker = true
        } else if let lastPath = recents.first?.path {
            // Reopen the last workspace but start a fresh chat — never pass
            // `lastSessionID`; the user resumes a saved session explicitly.
            await openWorkspace(URL(fileURLWithPath: lastPath), resumeSessionID: nil)
        }

        // Remote control is opt-in for the GUI. Starting it eagerly touches the
        // Keychain for paired-device tokens and TLS material, which is too
        // intrusive for a local-only chat launch.
    }

    private func startDaemonBackedUIIfRequested() async -> Bool {
        let env = Seams.live.environment.processEnvironment()
        guard env["CODEMIXER_UI_BACKEND"] == "daemon" else { return false }
        let client = RemoteEngineClient()
        do {
            try await client.connect()
        } catch {
            return false
        }
        remoteClient = client
        eventBus = client.bus
        viewModel = EngineViewModel(engine: client, bus: client.bus)
        showProjectPicker = true
        startTTSSubscription(bus: client.bus)
        return true
    }

    private func startTTSSubscription(bus: MulticastEventBus) {
        Task { [weak self] in
            guard let self else { return }
            let sub = await bus.subscribe()
            for await event in sub.stream {
                guard case .speakBubbleRequested(let payload) = event else { continue }
                await MainActor.run {
                    let parts = payload.split(separator: ":", maxSplits: 1)
                    let rawAction = parts.count > 1 ? String(parts[1]) : "play"
                    let action = TTSAction(rawValue: rawAction) ?? .play
                    let bubbleID = parts.first.map(String.init) ?? payload
                    switch action {
                    case .play:
                        // Find the assistant message whose id starts with the bubbleID segment.
                        let text = self.viewModel?.messages.first {
                            ($0.id.hasPrefix("asst-") || $0.id.hasPrefix("stream-"))
                            && $0.id.contains(bubbleID)
                        }.flatMap { $0.textContent } ?? ""
                        self.tts.speak(text: text, bubbleID: bubbleID)
                    case .pause: self.tts.pause()
                    case .stop:  self.tts.stop()
                    }
                }
            }
        }
    }

    func openWorkspace(_ url: URL, resumeSessionID: String?) async {
        showProjectPicker = false
        installHint = nil
        startupError = nil
        guard let engine = engine else {
            workspace = url
            viewModel?.send(.openProject(path: url.path, resumeSessionID: resumeSessionID))
            configureSlashCommands(for: url)
            return
        }
        await engine.shutdown(reason: .userCancel)
        let adapter = ClaudeAdapter()
        do {
            try await engine.start(adapter: adapter,
                                   workspace: url,
                                   resumeSessionID: resumeSessionID)
            workspace = url
        } catch let err as AgentError {
            if case .binaryNotFound(_, let hint) = err {
                // Surface the install-claude sheet.
                installHint = hint
            } else {
                startupError = err.userMessage
            }
            workspace = nil
            showProjectPicker = true
        } catch {
            startupError = error.localizedDescription
            workspace = nil
            showProjectPicker = true
        }
        recents = await engine.sessions.recents()
        if workspace != nil {
            configureSlashCommands(for: url)
        }
    }

    private func configureSlashCommands(for url: URL) {
        // Populate the slash-command palette from the adapter catalog + project commands.
        let claudeDir = Seams.live.environment.claudeDirectory
        let commands = ClaudeSlashCommands.builtIn +
            ClaudeSlashCommands.enumerateProjectCommands(workspace: url,
                                                         claudeDirectory: claudeDir)
        viewModel?.slashCommands = commands
    }

    func setRemoteHost(_ host: RemoteControlServer.BindHost) async {
        remoteHost = host
        guard let remote = await remoteRuntime?.server else { return }
        let config = RemoteControlServer.Configuration(
            host: host,
            port: RemoteDefaults.webSocketPort,
            requireAuth: true,
            useTLS: true
        )
        try? await remote.reconfigure(config)
        remoteFingerprint = await remote.certificateFingerprint
    }

    // MARK: - Remote control

    var isRemoteRunning: Bool { remoteRuntime != nil }

    func stopRemote() async {
        await remoteRuntime?.stop()
        remoteRuntime = nil
    }

    private func startRemote(engine: AgentEngine) async {
        guard remoteRuntime == nil else { return }
        let seams = Seams.live
        let pairing = await RemoteRuntimeCoordinator.makePairing(seams: seams)
        self.pairing = pairing
        let certificates = RemoteRuntimeCoordinator.makeCertificates(seams: seams)
        let runtime = RemoteRuntimeCoordinator(seams: seams,
                                                 pairing: pairing,
                                                 certificates: certificates)
        do {
            let remote = try await runtime.start(
                engine: engine,
                configuration: .init(host: remoteHost, requireAuth: true, useTLS: true)
            )
            remoteRuntime = runtime
            remoteFingerprint = await runtime.certificateFingerprint
            await remote.observeClientCount { [weak self] count in
                Task { @MainActor in self?.viewModel?.setConnectedRemoteClients(count) }
            }
        } catch { }
    }

    func remoteSettingsActions() -> RemoteSettingsActions {
        RemoteSettingsActions(
            refresh: { [weak self] in
                await self?.remoteSettingsState(pin: nil) ?? RemoteSettingsState()
            },
            startPairing: { [weak self] in
                guard let self else { return RemoteSettingsState() }
                if await MainActor.run(body: { self.remoteRuntime == nil }) {
                    guard let engine = await MainActor.run(body: { self.engine }) else {
                        return RemoteSettingsState()
                    }
                    await self.startRemote(engine: engine)
                }
                guard let pairing = await MainActor.run(body: { self.pairing }) else {
                    return RemoteSettingsState()
                }
                let pin = await pairing.startNewPairing()
                return await self.remoteSettingsState(pin: pin)
            },
            revoke: { [weak self] token in
                guard let self else { return RemoteSettingsState() }
                guard let pairing = await MainActor.run(body: { self.pairing }) else {
                    return RemoteSettingsState()
                }
                await pairing.revokeToken(token)
                return await self.remoteSettingsState(pin: nil)
            },
            installLaunchAgent: { [weak self] in
                guard let self else { return RemoteSettingsState() }
                do {
                    try await self.launchAgentInstaller.install()
                    return await self.remoteSettingsState(pin: nil, launchAgentDetail: "LaunchAgent installed.")
                } catch {
                    return await self.remoteSettingsState(pin: nil,
                                                          launchAgentDetail: "Install failed: \(error)")
                }
            },
            uninstallLaunchAgent: { [weak self] in
                guard let self else { return RemoteSettingsState() }
                do {
                    try await self.launchAgentInstaller.uninstall()
                    return await self.remoteSettingsState(pin: nil, launchAgentDetail: "LaunchAgent removed.")
                } catch {
                    return await self.remoteSettingsState(pin: nil,
                                                          launchAgentDetail: "Uninstall failed: \(error)")
                }
            },
            enableRemote: { [weak self] enabled in
                guard let self else { return RemoteSettingsState() }
                if enabled {
                    // Grab the engine reference on the main actor, then start the server.
                    if let engine = await MainActor.run(body: { self.engine }) {
                        await self.startRemote(engine: engine)
                    }
                } else {
                    await self.stopRemote()
                }
                return await self.remoteSettingsState(pin: nil)
            },
            setLANEnabled: { [weak self] enabled in
                guard let self else { return RemoteSettingsState() }
                let host: RemoteControlServer.BindHost = enabled ? .lan : .loopback
                await self.setRemoteHost(host)
                return await self.remoteSettingsState(pin: nil)
            }
        )
    }

    private func remoteSettingsState(pin: String?, launchAgentDetail: String? = nil) async -> RemoteSettingsState {
        let devices = await pairing?.allPaired().map {
            RemoteSettingsState.Device(id: $0.token,
                                       name: $0.deviceName,
                                       lastSeen: $0.lastSeen)
        } ?? []
        let fingerprint = remoteFingerprint
        let remoteRunning = isRemoteRunning
        let lan = remoteHost == .lan
        return RemoteSettingsState(pin: pin,
                                   certificateFingerprint: fingerprint,
                                   pairingURL: pairingURL(pin: pin, fingerprint: fingerprint),
                                   pairedDevices: devices.sorted { $0.name < $1.name },
                                   connectedClientCount: await remoteRuntime?.server?.connectedClientCount ?? 0,
                                   launchAgentInstalled: await launchAgentInstaller.isInstalled,
                                   launchAgentDetail: launchAgentDetail,
                                   remoteEnabled: remoteRunning,
                                   lanEnabled: lan)
    }

    private func pairingURL(pin: String?, fingerprint: String?) -> String? {
        guard let pin, let fingerprint else { return nil }
        let host = remoteHost == .loopback
            ? RemoteDefaults.loopbackHost
            : Seams.live.environment.deviceName
        var components = URLComponents()
        components.scheme = "codemixer"
        components.host = "pair"
        components.queryItems = [
            URLQueryItem(name: "host", value: host),
            URLQueryItem(name: "port", value: "\(RemoteDefaults.webSocketPort)"),
            URLQueryItem(name: "pin", value: pin),
            URLQueryItem(name: "fingerprint", value: fingerprint),
        ]
        return components.string
    }
}
