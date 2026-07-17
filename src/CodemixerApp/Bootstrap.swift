import SwiftUI
import AppKit
import AgentCore
import AgentUI
import AgentProtocol
import ClaudeCode
import Codex
import AgentRemoteControl

@MainActor
@Observable
final class Bootstrap {
    var viewModel: EngineViewModel?
    var workspace: URL?
    var remoteFingerprint: String?
    var remoteHost: RemoteControlServer.BindHost = .loopback
    var showProjectPicker: Bool = false
    var showNewProjectSheet: Bool = false
    var showSettings: Bool = false
    var showDebugTerminal: Bool = false
    var showEventLog: Bool = false
    var showSilentDiagnostics: Bool = false
    var authURL: URL?
    var recents: [SessionStore.ProjectRecord] = []
    var startupError: String?
    /// Non-nil when the last `openWorkspace` failed with `binaryNotFound`.
    var installHint: String?
    /// Folder chosen via Open Project that has no stored agent mode yet.
    var pendingConfigureURL: URL?
    var pendingConfigureResumeSessionID: String?

    let voice = VoiceInputService()
    let tts = TTSService()
    private let notifications = UserNotificationBridge()

    var engine: AgentEngine?
    /// Mode B only: loopback `RemoteEngineClient` that implements
    /// `AgentEngineCommandPort` for `EngineViewModel`. Not the server's
    /// connected-peer count — see `EngineViewModel.connectedRemoteClients`.
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
        await AdapterRegistry.shared.register(CodexAdapter())

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
        model.availableModels = []

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
        // Otherwise show the Open Project picker.
        if let active = await projectsStore.activeWorkspaceURL() {
            await openWorkspace(active, resumeSessionID: nil)
        } else {
            presentProjectPicker()
        }

        // Remote control is opt-in for the GUI. Starting it eagerly touches the
        // Keychain for paired-device tokens and TLS material, which is too
        // intrusive for a local-only chat launch.
    }

    /// Reliable entry point for File → Open Project. Mutating the flag through
    /// a method (rather than a menu closure capturing `@State`) keeps SwiftUI
    /// observation wired when the sheet was previously dismissed.
    func presentProjectPicker() {
        pendingConfigureURL = nil
        pendingConfigureResumeSessionID = nil
        showProjectPicker = true
    }

    /// File → New Workspace: close the current workspace (if any) and pick a folder.
    func presentNewWorkspace() async {
        if workspace != nil {
            await closeWorkspace()
        } else {
            presentProjectPicker()
        }
    }

    /// File → New Project: create a subfolder project in the open workspace.
    func presentNewProjectSheet() {
        guard workspace != nil else { return }
        showNewProjectSheet = true
    }

    /// File → Close Workspace: clear the active-workspace restore flag, shut
    /// down the agent, and return to the project picker.
    func closeWorkspace() async {
        showProjectPicker = false
        showNewProjectSheet = false
        pendingConfigureURL = nil
        pendingConfigureResumeSessionID = nil
        installHint = nil
        startupError = nil
        try? await viewModel?.workspaceProjects?.clearActiveWorkspace()
        if let engine {
            await engine.shutdown(reason: .userCancel)
            recents = await engine.sessions.recents()
        }
        workspace = nil
        viewModel?.resetForClosedWorkspace()
        presentProjectPicker()
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
        remoteClient = client
        eventBus = client.bus
        let model = EngineViewModel(engine: client, bus: client.bus)
        model.availableModels = adapter.availableModels()
        viewModel = model
        presentProjectPicker()
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

    /// Opens a folder after resolving its agent mode from project-local state
    /// or the workspace index. If neither knows the mode, presents the
    /// configure sheet instead of guessing.
    func openWorkspace(_ url: URL, resumeSessionID: String?) async {
        showProjectPicker = false
        let resolved: ProjectAgentMode?
        if let store = viewModel?.workspaceProjects {
            resolved = await store.resolveAgentMode(for: url)
        } else {
            resolved = ProjectLocalStateStore.load(from: url, fileSystem: Seams.live.fileSystem)?.agentMode
        }
        if let mode = resolved {
            await openWorkspace(url, resumeSessionID: resumeSessionID, agentMode: mode)
            return
        }
        pendingConfigureURL = url
        pendingConfigureResumeSessionID = resumeSessionID
    }

    func confirmPendingProjectConfiguration(mode: ProjectAgentMode) async {
        guard let url = pendingConfigureURL else { return }
        let resume = pendingConfigureResumeSessionID
        pendingConfigureURL = nil
        pendingConfigureResumeSessionID = nil
        await openWorkspace(url, resumeSessionID: resume, agentMode: mode)
    }

    func cancelPendingProjectConfiguration() {
        pendingConfigureURL = nil
        pendingConfigureResumeSessionID = nil
        if workspace == nil {
            presentProjectPicker()
        }
    }

    func openWorkspace(_ url: URL, resumeSessionID: String?, agentMode: ProjectAgentMode) async {
        showProjectPicker = false
        pendingConfigureURL = nil
        pendingConfigureResumeSessionID = nil
        installHint = nil
        startupError = nil
        guard let engine = engine else {
            workspace = url
            viewModel?.send(.openProject(path: url.path, resumeSessionID: resumeSessionID))
            try? await viewModel?.workspaceProjects?.markActiveWorkspace(url)
            Task { await configureSlashCommands(for: url, mode: agentMode) }
            return
        }
        await engine.shutdown(reason: .userCancel)
        let projectsStore = viewModel?.workspaceProjects
        _ = await projectsStore?.projects(for: url, rootMode: agentMode)
        if let store = projectsStore {
            _ = try? await store.setAgentMode(path: url.path, mode: agentMode, in: url)
        }

        guard let adapter = await Self.adapter(for: agentMode) else {
            startupError = "Select a concrete agent for this mixed or custom project before starting a session."
            workspace = nil
            try? await projectsStore?.clearActiveWorkspace()
            presentProjectPicker()
            return
        }
        do {
            try await engine.start(adapter: adapter,
                                   workspace: url,
                                   resumeSessionID: resumeSessionID)
            workspace = url
            viewModel?.availableModels = adapter.availableModels()
            viewModel?.supportsResumableSessions = adapter.capabilities.contains(.resumableSessions)
            viewModel?.refreshProjects(rootMode: agentMode)
            try? await projectsStore?.markActiveWorkspace(url)
        } catch let err as AgentError {
            if case .binaryNotFound(_, let hint) = err {
                installHint = hint
            } else {
                startupError = err.userMessage
            }
            workspace = nil
            try? await projectsStore?.clearActiveWorkspace()
            presentProjectPicker()
        } catch {
            startupError = error.localizedDescription
            workspace = nil
            try? await projectsStore?.clearActiveWorkspace()
            presentProjectPicker()
        }
        recents = await engine.sessions.recents()
        if workspace != nil {
            await configureSlashCommands(for: url, mode: agentMode)
        }
    }

    func configureSlashCommands(for url: URL, mode: ProjectAgentMode) async {
        guard let adapter = await Self.adapter(for: mode) else {
            viewModel?.slashCommands = []
            return
        }
        let projectCommands = await adapter.enumerateProjectCommands(workspace: url)
        viewModel?.slashCommands = adapter.slashCommandCatalog + projectCommands
    }

    private static func adapter(for mode: ProjectAgentMode) async -> (any AgentAdapter)? {
        await ProjectAgentRouter.resolveAdapter(mode: mode)
    }

    private static func listSessions(for url: URL) async -> [SessionSummary] {
        let adapters = await AdapterRegistry.shared.all()
        var sessions: [SessionSummary] = []
        for adapter in adapters where adapter.capabilities.contains(.resumableSessions) {
            sessions += await adapter.listResumableSessions(workspace: url)
        }
        return sessions.sorted { $0.lastActivity > $1.lastActivity }
    }
}
