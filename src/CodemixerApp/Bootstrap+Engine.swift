import Foundation
import AgentCore
import AgentUI
import AgentProtocol
import ClaudeCode
import Codex
import AgentClientProtocol
import ACPCLIs
import AgentRemoteControl

extension Bootstrap {

    // MARK: - Startup

    func start() async {
        guard viewModel == nil else { return }
        defer { isStartupComplete = true }

        let adapter = ClaudeAdapter()
        await AdapterRegistry.shared.register(adapter)
        await AdapterRegistry.shared.register(CodexAdapter())
        await AdapterRegistry.shared.register(CursorACPAdapter())
        await CustomAgentAdapterFactories.shared.register(CustomACPAdapterFactory())

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
        engineBackend = .inProcess(engine)
        await engine.bootstrap()

        let model = EngineViewModel(engine: engine, bus: engine.bus)
        viewModel = model
        model.availableModels = []
        model.availableAgentModes = []
        model.selectedAgentModeID = ""

        // Session navigator wiring (agent-agnostic): the lister resolves the
        // adapter via the registry so AgentUI never imports a concrete adapter.
        let projectsStore = WorkspaceProjectsStore(environment: Seams.live.environment,
                                                   fileSystem: Seams.live.fileSystem)
        await projectsStore.load()
        model.workspaceProjects = projectsStore
        model.sessionLister = { url in
            await Self.listSessions(for: url)
        }
        model.supportsResumableSessions = true
        model.sidebarVisible = await engine.prefs.state().appearance.sidebarVisible
        model.hydrate(from: await engine.prefs.state())

        startAppEventBridge(bus: engine.bus)

        // Restore the last open workspace when the user did not Close Workspace.
        // Otherwise show the blank landing (File → Open Workspace remains available).
        if let active = await projectsStore.activeWorkspaceURL() {
            await openWorkspace(active, resumeSessionID: nil)
        }

        // Remote control is opt-in for the GUI. Starting it eagerly touches the
        // Keychain for paired-device tokens and TLS material, which is too
        // intrusive for a local-only chat launch.
    }

    func connectDaemonBackedUI(adapter: ClaudeAdapter) async -> Bool {
        // Client role: GUI becomes a WebSocket consumer of codemixerd (Mode B).
        // On success there is no in-process AgentEngine — see architecture.md §4.1.
        let client = RemoteEngineClient(configuration: .init(reconnect: .daemon))
        do {
            try await client.connect()
        } catch {
            return false
        }
        engineBackend = .remote(client)
        let model = EngineViewModel(engine: client, bus: client.bus)
        model.availableModels = adapter.availableModels()
        model.availableAgentModes = adapter.availableAgentModes()
        model.selectedAgentModeID = adapter.availableAgentModes().first?.id ?? ""
        viewModel = model
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
                case .speakBubbleRequested(let eventID, let action):
                    let bubbleID = eventID.uuidString
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

    static func adapter(for mode: ProjectType) async -> (any AgentAdapter)? {
        await ProjectAgentRouter.resolveAdapter(projectType: mode)
    }

    static func listSessions(for url: URL) async -> [SessionSummary] {
        var sessions: [SessionSummary] = []
        var seen = Set<String>()

        func append(_ batch: [SessionSummary]) {
            for summary in batch {
                let key = "\(summary.agentID.rawValue)::\(summary.id)"
                guard seen.insert(key).inserted else { continue }
                sessions.append(summary)
            }
        }

        let adapters = await AdapterRegistry.shared.all()
        for adapter in adapters where adapter.capabilities.contains(.resumableSessions) {
            append(await adapter.listResumableSessions(workspace: url))
        }

        // Custom ACP adapters live in the factory cache, not AdapterRegistry.
        if let local = ProjectLocalStateStore.load(
            from: url,
            fileSystem: Seams.live.fileSystem
        ),
           case .custom = local.projectType,
           let adapter = await ProjectAgentRouter.resolveAdapter(projectType: local.projectType),
           adapter.capabilities.contains(.resumableSessions) {
            append(await adapter.listResumableSessions(workspace: url))
        }

        return sessions.sorted { $0.lastActivity > $1.lastActivity }
    }
}
