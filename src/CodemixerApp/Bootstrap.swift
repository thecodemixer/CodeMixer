import SwiftUI
import AppKit
import AgentCore
import AgentUI
import AgentProtocol
import ClaudeCode
import Codex
import AgentClientProtocol
import ACPCLIs
import AgentRemoteControl

@MainActor
@Observable
final class Bootstrap {
    var viewModel: EngineViewModel?
    var workspace: URL?
    var remoteFingerprint: String?
    var remoteHost: RemoteControlServer.BindHost = .loopback
    var showProjectPicker: Bool = false
    var showOpenProject: Bool = false
    var showNewProjectSheet: Bool = false
    var showNewWorkspaceSheet: Bool = false
    var showDebugTerminal: Bool = false
    var showEventLog: Bool = false
    var showSilentDiagnostics: Bool = false
    var recents: [SessionStore.ProjectRecord] = []
    var startupError: String?
    /// False until `start()` finishes engine bootstrap and optional workspace restore.
    var isStartupComplete = false
    /// True while opening a workspace and waiting for model catalogs to load.
    /// The main workspace UI stays hidden until this clears.
    var isPreparingWorkspace = false
    /// Folder chosen via Open Project that has no stored project type yet.
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

    /// Shared create/open workspace paths (model-catalog warm included).
    private var workspaceLifecycle: WorkspaceLifecycle? {
        viewModel.map { WorkspaceLifecycle(model: $0) }
    }

    var bus: MulticastEventBus? { eventBus }

    var debugTerminalSnapshotText: (@Sendable () async -> String)? {
        guard let engine else { return nil }
        return { await engine.terminalSnapshotText() }
    }

    func start() async {
        guard viewModel == nil else { return }
        defer { isStartupComplete = true }

        let adapter = ClaudeAdapter()
        await AdapterRegistry.shared.register(adapter)
        await AdapterRegistry.shared.register(CodexAdapter())
        await AdapterRegistry.shared.register(CursorACPAdapter())
        await CustomAgentAdapterFactories.shared.register(ACPCustomAgentAdapterFactory())

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

    /// File → Open Workspace: shows the recents picker so the user can switch
    /// to an existing workspace or choose a new folder.
    func presentProjectPicker() {
        pendingConfigureURL = nil
        pendingConfigureResumeSessionID = nil
        showProjectPicker = true
    }

    /// File → Open Project: shows the same project picker dialog.
    func presentOpenProject() {
        pendingConfigureURL = nil
        pendingConfigureResumeSessionID = nil
        showOpenProject = true
    }

    /// File → New Workspace: dedicated sheet for name + parent folder + project type.
    func presentNewWorkspaceSheet() {
        showNewWorkspaceSheet = true
    }

    /// Creates `<parent>/<name>/`, tears down any open workspace without
    /// bouncing through the Open Project picker, then adopts the folder as an
    /// empty workspace shell. Project type is chosen later via New Project.
    func createWorkspace(name: String, parentDirectory: URL) async {
        showNewWorkspaceSheet = false
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty,
              trimmed != ".",
              trimmed != "..",
              !trimmed.contains("/"),
              !trimmed.contains("\\") else {
            startupError = "Enter a valid workspace name."
            return
        }
        let folder = parentDirectory.appendingPathComponent(trimmed, isDirectory: true)
        let fs = Seams.live.fileSystem
        if fs.isDirectory(at: folder) || fs.fileExists(at: folder) {
            startupError = "A folder named “\(trimmed)” already exists in that location."
            return
        }
        do {
            try fs.createDirectory(at: folder, withIntermediates: true)
        } catch {
            startupError = error.localizedDescription
            return
        }
        await leaveWorkspaceWithoutPicker()
        isPreparingWorkspace = true
        defer { isPreparingWorkspace = false }
        do {
            guard let lifecycle = workspaceLifecycle else { return }
            try await lifecycle.openEmptyWorkspace(folder)
            workspace = folder
        } catch {
            startupError = error.localizedDescription
            workspace = nil
            workspaceLifecycle?.abortOpen()
        }
    }

    /// File → New Project: create a subfolder project in the open workspace.
    func presentNewProjectSheet() {
        guard workspace != nil else { return }
        showNewProjectSheet = true
    }

    /// File → Close Workspace: clear the active-workspace restore flag, shut
    /// down the agent, and return to the landing screen.
    func closeWorkspace() async {
        await leaveWorkspaceWithoutPicker()
    }

    /// Tears down the open workspace without presenting the Open Project picker.
    private func leaveWorkspaceWithoutPicker() async {
        showProjectPicker = false
        showNewProjectSheet = false
        showNewWorkspaceSheet = false
        pendingConfigureURL = nil
        pendingConfigureResumeSessionID = nil
        startupError = nil
        try? await viewModel?.workspaceProjects?.clearActiveWorkspace()
        if let engine {
            await engine.shutdown(reason: .userCancel)
            recents = await engine.sessions.recents()
        }
        workspace = nil
        isPreparingWorkspace = false
        viewModel?.resetForClosedWorkspace()
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

    /// Opens a folder after resolving its project type from project-local state
    /// or the workspace index. If neither knows the mode, presents the
    /// configure sheet instead of guessing.
    func openWorkspace(_ url: URL, resumeSessionID: String?) async {
        showProjectPicker = false
        let resolved: ProjectType?
        if let store = viewModel?.workspaceProjects {
            resolved = await store.resolveProjectType(for: url)
        } else {
            resolved = ProjectLocalStateStore.load(from: url, fileSystem: Seams.live.fileSystem)?.projectType
        }
        if let mode = resolved {
            await openWorkspace(url, resumeSessionID: resumeSessionID, projectType: mode)
            return
        }
        // Empty workspace shell: adopted via New Workspace with no projects yet.
        if let store = viewModel?.workspaceProjects {
            let existing = await store.projects(for: url)
            if existing.isEmpty {
                isPreparingWorkspace = true
                defer { isPreparingWorkspace = false }
                do {
                    guard let lifecycle = workspaceLifecycle else { return }
                    try await lifecycle.openEmptyWorkspace(url)
                    workspace = url
                } catch {
                    startupError = error.localizedDescription
                    workspace = nil
                    workspaceLifecycle?.abortOpen()
                    try? await store.clearActiveWorkspace()
                }
                return
            }
        }
        pendingConfigureURL = url
        pendingConfigureResumeSessionID = resumeSessionID
    }

    func confirmPendingProjectConfiguration(mode: ProjectType) async {
        guard let url = pendingConfigureURL else { return }
        let resume = pendingConfigureResumeSessionID
        pendingConfigureURL = nil
        pendingConfigureResumeSessionID = nil
        await openWorkspace(url, resumeSessionID: resume, projectType: mode)
    }

    func cancelPendingProjectConfiguration() {
        pendingConfigureURL = nil
        pendingConfigureResumeSessionID = nil
    }

    func openWorkspace(_ url: URL, resumeSessionID: String?, projectType: ProjectType) async {
        showProjectPicker = false
        pendingConfigureURL = nil
        pendingConfigureResumeSessionID = nil
        startupError = nil
        isPreparingWorkspace = true
        defer { isPreparingWorkspace = false }

        guard let engine = engine else {
            do {
                guard let lifecycle = workspaceLifecycle else { return }
                try await lifecycle.loadModelCatalogs(at: url, rootProjectType: projectType)
            } catch {
                startupError = error.localizedDescription
                workspace = nil
                workspaceLifecycle?.abortOpen()
                return
            }
            await viewModel?.prepareProjectOpen(url: url, projectType: projectType)
            await viewModel?.reloadProjects(rootProjectType: projectType)
            viewModel?.send(.openProject(path: url.path, resumeSessionID: resumeSessionID))
            try? await viewModel?.workspaceProjects?.markActiveWorkspace(url)
            Task { await configureSlashCommands(for: url, mode: projectType) }
            workspace = url
            return
        }
        await engine.shutdown(reason: .userCancel)
        let projectsStore = viewModel?.workspaceProjects
        if let store = projectsStore {
            _ = await store.projects(for: url, rootProjectType: projectType)
            _ = try? await store.setProjectType(path: url.path, projectType: projectType, in: url)
        }

        guard let adapter = await Self.adapter(for: projectType) else {
            startupError = "Select a concrete agent for this mixed or custom project before starting a session."
            workspace = nil
            workspaceLifecycle?.abortOpen()
            try? await projectsStore?.clearActiveWorkspace()
            return
        }

        // Model catalogs for adapters used in this workspace must be ready
        // before the workspace UI is shown — same path as create / empty open.
        do {
            guard let lifecycle = workspaceLifecycle else { return }
            try await lifecycle.loadModelCatalogs(at: url, rootProjectType: projectType)
        } catch {
            startupError = error.localizedDescription
            workspace = nil
            workspaceLifecycle?.abortOpen()
            try? await projectsStore?.clearActiveWorkspace()
            return
        }

        do {
            // Gate the composer before spawn so Cursor ACP's ~20s
            // initialize/auth/session-new cannot race an early send.
            await viewModel?.prepareProjectOpen(url: url, projectType: projectType)
            await viewModel?.reloadProjects(rootProjectType: projectType)
            try await engine.start(adapter: adapter,
                                   workspace: url,
                                   resumeSessionID: resumeSessionID)
            viewModel?.supportsResumableSessions = adapter.capabilities.contains(.resumableSessions)
            viewModel?.availableModels = adapter.availableModels()
            viewModel?.availableAgentModes = adapter.availableAgentModes()
            viewModel?.selectedAgentModeID = adapter.availableAgentModes().first?.id ?? ""
            try? await projectsStore?.markActiveWorkspace(url)
            workspace = url
        } catch let err as AgentError {
            startupError = err.userMessage
            workspace = nil
            workspaceLifecycle?.abortOpen()
            try? await projectsStore?.clearActiveWorkspace()
        } catch {
            startupError = error.localizedDescription
            workspace = nil
            workspaceLifecycle?.abortOpen()
            try? await projectsStore?.clearActiveWorkspace()
        }
        recents = await engine.sessions.recents()
        if workspace != nil {
            await configureSlashCommands(for: url, mode: projectType)
        }
    }

    func configureSlashCommands(for url: URL, mode: ProjectType) async {
        guard let adapter = await Self.adapter(for: mode) else {
            viewModel?.slashCommands = []
            return
        }
        let projectCommands = await adapter.enumerateProjectCommands(workspace: url)
        viewModel?.slashCommands = adapter.slashCommandCatalog + projectCommands
    }

    private static func adapter(for mode: ProjectType) async -> (any AgentAdapter)? {
        await ProjectAgentRouter.resolveAdapter(projectType: mode)
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
