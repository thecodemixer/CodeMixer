import SwiftUI
import AppKit
import AgentCore
import AgentUI
import AgentProtocol
import ClaudeCode
import AgentRemoteControl

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
    var showSilentDiagnostics: Bool = false
    var authURL: URL?
    var recents: [SessionStore.ProjectRecord] = []
    var startupError: String?
    /// Non-nil when the last `openWorkspace` failed with `binaryNotFound`.
    var installHint: String?

    let voice = VoiceInputService()
    let tts = TTSService()
    private let notifications = UserNotificationBridge()

    var engine: AgentEngine?
    var remoteClient: RemoteEngineClient?
    var eventBus: MulticastEventBus?
    var remoteRuntime: RemoteRuntimeCoordinator?
    var pairing: PairingService?
    private var appEventTask: Task<Void, Never>?
    let launchAgentInstaller = LaunchAgentInstaller()

    var bus: MulticastEventBus? { eventBus }

    var debugTerminalSnapshotText: (@Sendable () async -> String)? {
        guard let engine else { return nil }
        return { await engine.terminalSnapshotText() }
    }

    func start() async {
        guard viewModel == nil else { return }

        let adapter = ClaudeAdapter()
        await AdapterRegistry.shared.register(adapter)

        let env = Seams.live.environment.processEnvironment()
        if env["CODEMIXER_UI_BACKEND"] == "daemon" {
            if await connectDaemonBackedUI(adapter: adapter) { return }
            await SilentDiagnostics.shared.record(kind: .modeBFallback,
                                                  owner: "Bootstrap",
                                                  summary: "CODEMIXER_UI_BACKEND=daemon connect failed; using in-process engine")
        } else if await launchAgentInstaller.isInstalled {
            if await connectDaemonBackedUI(adapter: adapter) { return }
            await SilentDiagnostics.shared.record(kind: .modeBFallback,
                                                  owner: "Bootstrap",
                                                  summary: "LaunchAgent daemon unreachable; using in-process engine")
        }

        let engine = AgentEngine()
        self.engine = engine
        await engine.bootstrap()

        let model = EngineViewModel(engine: engine, bus: engine.bus)
        viewModel = model
        eventBus = engine.bus
        recents = await engine.sessions.recents()
        model.availableModels = adapter.availableModels()

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

        startAppEventBridge(bus: engine.bus)

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

    func connectDaemonBackedUI(adapter: ClaudeAdapter) async -> Bool {
        let client = RemoteEngineClient(configuration: .init(reconnect: .daemon))
        do {
            try await client.connect()
        } catch {
            return false
        }
        remoteClient = client
        eventBus = client.bus
        let model = EngineViewModel(engine: client, bus: client.bus)
        model.availableModels = adapter.availableModels()
        viewModel = model
        showProjectPicker = true
        startAppEventBridge(bus: client.bus)
        return true
    }

    func startAppEventBridge(bus: MulticastEventBus) {
        notifications.requestPermission()
        appEventTask?.cancel()
        appEventTask = Task { @MainActor [weak self] in
            guard let self else { return }
            let sub = await bus.subscribe()
            for await entry in sub.stream {
                switch entry.event {
                case .authURL(let url):
                    self.authURL = url
                case .speakBubbleRequested(let payload):
                    let parts = payload.split(separator: ":", maxSplits: 1)
                    let rawAction = parts.count > 1 ? String(parts[1]) : "play"
                    let action = TTSAction(rawValue: rawAction) ?? .play
                    let bubbleID = parts.first.map(String.init) ?? payload
                    switch action {
                    case .play:
                        let text = self.viewModel?.messages.first {
                            ($0.id.hasPrefix("asst-") || $0.id.hasPrefix("stream-"))
                            && $0.id.contains(bubbleID)
                        }.flatMap { $0.textContent } ?? ""
                        self.tts.speak(text: text, bubbleID: bubbleID)
                    case .pause: self.tts.pause()
                    case .stop:  self.tts.stop()
                    }
                case .bell:
                    self.notifications.bell()
                case .statusPhraseChanged(let source, let phrase) where source == .hookHint:
                    self.notifications.notify(title: "Claude", body: phrase)
                default:
                    break
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

    func configureSlashCommands(for url: URL) {
        // Populate the slash-command palette from the adapter catalog + project commands.
        let claudeDir = Seams.live.environment.claudeDirectory
        let commands = ClaudeSlashCommands.builtIn +
            ClaudeSlashCommands.enumerateProjectCommands(workspace: url,
                                                         claudeDirectory: claudeDir)
        viewModel?.slashCommands = commands
    }
}
