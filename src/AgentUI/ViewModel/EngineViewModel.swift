import Foundation
import Observation
import SwiftUI
import AgentCore
import AgentProtocol

/// The detail pane's current surface for the active project.
///
/// Not `Sendable`: constructed and read only on the main actor, alongside
/// every other `EngineViewModel` field.
public enum DetailPanePresentation: Equatable {
    case conversation
    case dashboard
    /// The file list for a non-agent folder project. `pendingRelativePath`
    /// is a one-shot instruction the browser view consumes on the next
    /// appearance (opening a sidebar shortcut before the browser exists yet);
    /// `selectedRelativePath` is the already-consumed, currently-highlighted
    /// selection.
    case folderBrowser(kind: FolderProjectKind, selectedRelativePath: String?, pendingRelativePath: String?)
    /// Same folder project, but the pane shows only the file preview
    /// (sidebar pin opened directly into a file). Always has a concrete
    /// path — there is nothing to preview otherwise.
    case folderPreviewOnly(kind: FolderProjectKind, relativePath: String)

    var isFolderBrowser: Bool {
        switch self {
        case .folderBrowser, .folderPreviewOnly: return true
        case .conversation, .dashboard: return false
        }
    }

    var isFolderPreviewOnly: Bool {
        if case .folderPreviewOnly = self { return true }
        return false
    }

    var folderProjectKind: FolderProjectKind? {
        switch self {
        case .folderBrowser(let kind, _, _), .folderPreviewOnly(let kind, _): return kind
        case .conversation, .dashboard: return nil
        }
    }

    var activeFolderSelectionRelativePath: String? {
        switch self {
        case .folderBrowser(_, let selected, _): return selected
        case .folderPreviewOnly(_, let path): return path
        case .conversation, .dashboard: return nil
        }
    }
}

/// A Custom ACP CLI restart's progress through close → respawn → re-advertise.
public enum CustomACPRestartPhase: Equatable {
    /// No restart in flight.
    case idle
    /// The old process has been asked to close; a cold `openProject` for the
    /// respawned process hasn't been sent yet.
    case tearingDown
    /// Cold `openProject` was sent. Waiting for the respawned agent's first
    /// `agentDashboard` advertisement — anything from the old process's
    /// in-flight requests before this point is stale and must be ignored.
    case awaitingDashboard
}

/// `@MainActor` `@Observable` projection of the engine's event stream into
/// SwiftUI-readable state.
///
/// Views read from this; commands are sent through `engine.send(_:)` (the
/// `AgentEngineCommandPort`). All mutation happens on the main actor —
/// background work belongs in the engine, not here.
@MainActor
@Observable
public final class EngineViewModel {

    // MARK: - Public state (read-only)

    public internal(set) var sessionID: String?
    /// Project paths with a live or parked pooled agent process in this workspace.
    public internal(set) var livePooledProjectPaths: Set<String> = []
    /// Active project cwd from the agent session (conversation / diff / composer).
    public internal(set) var workspace: URL?
    /// Loaded workspace folder (one per window). Owns the projects list in the
    /// sidebar; distinct from `workspace`, which tracks the active project cwd.
    /// Set by the app shell when adopting / opening / closing a workspace.
    public var workspaceRoot: URL?
    public internal(set) var messages: [Message] = []
    public internal(set) var activeToolCalls: [ToolCallEntry] = []
    /// Pending permission prompts keyed by owning session id.
    ///
    /// Background ACP reviews stay parked until that session is foregrounded;
    /// this map keeps each live prompt tied to the chat that owns it so the
    /// composer card never leaks onto unrelated sessions. The sidebar orange
    /// attention dot remains the cross-session signal.
    public internal(set) var pendingPermissionsBySession: [String: PermissionPrompt] = [:]
    /// Prompt for the currently selected session only (composer / overview card).
    public var activePendingPermission: PermissionPrompt? {
        pendingPermissionsBySession[permissionOwnerKey(for: sessionID)]
    }
    /// Sentinel key when a prompt arrives before any session id is known
    /// (single-session Claude / Codex paths).
    static let unscopedPermissionSessionKey = ""
    /// Which surface the detail pane shows for the active project: chat,
    /// the non-agent folder browser (with its selection state), or the
    /// dashboard. Stored as the single source of truth so the previous six
    /// independently-mutated fields (`showsFolderBrowser`, `showsPreviewOnly`,
    /// `activeFolderProjectKind`, `activeFolderSelectionRelativePath`,
    /// `pendingFolderSelectionRelativePath`, `showsOverviewDashboard`) — which
    /// had to move in lockstep by convention to avoid representing e.g.
    /// "folder browser and dashboard both active" — collapse into one value.
    /// `dashboardURL`/`dashboardTitle` stay separate: they cache the current
    /// project's dashboard address independent of whether the dashboard
    /// surface is currently selected (an `agentDashboard` advertisement must
    /// never steal focus from a file chat, but its URL is still worth caching
    /// for the next time the user picks Overview).
    public internal(set) var detailPane: DetailPanePresentation = .conversation
    public internal(set) var dashboardURL: URL?
    public internal(set) var dashboardTitle: String?
    /// Selects the detail pane's dashboard when available. Overview sessions
    /// default this to true; file sessions default to chat.
    public var showsOverviewDashboard: Bool { detailPane == .dashboard }
    /// True while the detail pane shows a non-agent folder browser.
    public var showsFolderBrowser: Bool { detailPane.isFolderBrowser }
    /// Active folder project kind when `showsFolderBrowser` is true.
    public var activeFolderProjectKind: FolderProjectKind? { detailPane.folderProjectKind }
    /// Relative path to preselect when opening a folder shortcut from the sidebar.
    public var pendingFolderSelectionRelativePath: String? {
        get {
            if case .folderBrowser(_, _, let pending) = detailPane { return pending }
            return nil
        }
        set {
            guard case .folderBrowser(let kind, let selected, _) = detailPane else { return }
            detailPane = .folderBrowser(kind: kind, selectedRelativePath: selected, pendingRelativePath: newValue)
        }
    }
    /// Currently selected file in the folder browser (drives sidebar active marker).
    public var activeFolderSelectionRelativePath: String? { detailPane.activeFolderSelectionRelativePath }
    /// When true, the folder detail pane shows only the file preview (sidebar pin open).
    public var showsPreviewOnly: Bool { detailPane.isFolderPreviewOnly }
    /// Pinned relative paths keyed by project path (pin-capable folder kinds).
    public internal(set) var folderPinnedPathsByProject: [String: [String]] = [:]
    /// Automatic newest-log shortcuts keyed by project path.
    public internal(set) var folderAutomaticShortcutsByProject: [String: [FolderSidebarShortcut]] = [:]
    /// Where a Custom ACP CLI restart is in its close → respawn → re-advertise
    /// sequence. Stored as one value so "waiting for a dashboard advertisement"
    /// can never be represented before the old process has actually been torn
    /// down — the two booleans this replaced could disagree about that.
    public internal(set) var customACPRestartPhase: CustomACPRestartPhase = .idle
    /// True while Restart ACP CLI has closed the process and is waiting for a
    /// fresh `agentDashboard` from the respawned Custom ACP agent.
    public var isRestartingCustomACPCLI: Bool { customACPRestartPhase != .idle }
    /// Set after cold `openProject` succeeds; `agentDashboard` before this is ignored.
    var customACPRestartAwaitingDashboard: Bool { customACPRestartPhase == .awaitingDashboard }
    /// Bumped on each Custom ACP restart so the WebView reloads even if the
    /// advertised dashboard URL string is unchanged.
    public internal(set) var dashboardLoadGeneration: Int = 0
    public internal(set) var diagnostics: [DiagnosticEntry] = []
    public internal(set) var status: StatusLine = .idle
    public internal(set) var activity: ActivitySubstate = .idle
    public internal(set) var changedFiles: [String] = []
    /// WebSocket peers attached to `RemoteControlServer` (server-side count).
    /// In Mode B includes the loopback GUI; in Mode A counts external peers only.
    /// See `docs/architecture.md` §4.1 and `Remote/AgentRemoteControl/README.md`.
    public internal(set) var connectedRemoteClients: Int = 0
    public internal(set) var isSwitchingSession: Bool = false
    /// Active session was restored from Codemixer's project cache because the
    /// ACP agent reported that it no longer owns the session.
    public internal(set) var cachedTranscriptLoadedSessionID: String?
    var composerGateState: ComposerGateState = .unlocked
    /// Holds the composer closed briefly after opening a saved session so the
    /// first prompt cannot race Claude's resume/startup TUI.
    var isComposerLockedForSessionResume: Bool { composerGateState.isLocked }
    /// True while the composer lock was armed by `.sessionHandshakeGate`
    /// (Cursor / ACP). History replay must not clear this — only SessionStart.
    internal var isComposerLockedForSessionHandshake: Bool { composerGateState.isHandshake }
    /// Same-project warm `session/load` (process already live) — shorter hard
    /// unlock and "Loading session…" copy instead of cold-spawn messaging.
    var isWarmSessionSwitch: Bool { composerGateState.isWarmSessionSwitch }
    /// Claude Code resume has two clocks: the UI can replay JSONL history
    /// quickly, while the live `claude --resume` PTY may still be painting
    /// history and not yet accepting input. While true, replayed content may
    /// end the visual switch state but must not unlock the composer.
    internal var isComposerWaitingForClaudeCodeResume: Bool { composerGateState.waitsForClaudeCodeResume }
    public internal(set) var sessionTokens: Int = 0
    public internal(set) var sessionCostUSD: Double?
    public internal(set) var appearancePrefs: AppearancePrefs = .init()
    public internal(set) var autoApprovalRules: [AutoApprovalRule] = []
    public var availableModels: [AgentModelOption] = []
    /// Session modes published by the active adapter for the composer dropdown.
    public var availableAgentModes: [AgentModeOption] = []
    /// Currently selected composer session mode id (from `availableAgentModes`).
    public var selectedAgentModeID: String = ""
    /// Per-adapter model catalog rows for Workspace settings.
    public internal(set) var workspaceModelCatalogRows: [WorkspaceModelCatalogRow] = []
    /// Agent currently running a manual model refresh, if any.
    public internal(set) var modelCatalogRefreshInFlight: AgentID?

    public var showUsageChip: Bool { appearancePrefs.showUsageChip }
    public var showSilentRecoveryLog: Bool { appearancePrefs.showSilentRecoveryLog }

    /// Updates the live remote-client count shown in the toolbar chip. Called
    /// from the remote-control server's connection observer (GUI mode only);
    /// headless surfaces read the count directly off the server.
    public func setConnectedRemoteClients(_ count: Int) {
        connectedRemoteClients = count
    }

    /// Hydrate UI-facing prefs from the engine store at startup.
    public func hydrate(from prefs: PrefsStore.State) {
        appearancePrefs = prefs.appearance
        autoApprovalRules = prefs.autoApprovalRules
        sidebarVisible = prefs.appearance.sidebarVisible
    }

    public func syncAutoApprovalRules(_ rules: [AutoApprovalRule]) {
        autoApprovalRules = rules
    }

    // MARK: - Session navigator state

    /// Display name for the active project (window title / top bar).
    public var currentProjectDisplayName: String {
        guard let path = workspace?.path else { return "Codemixer" }
        if let name = projects.first(where: { $0.path == path })?.displayName {
            return name
        }
        return URL(fileURLWithPath: path).lastPathComponent
    }

    /// Whether the session navigator rail is shown. GUI chrome only — persisted
    /// via `AppearancePrefs`, never on the wire.
    public var sidebarVisible: Bool = true

    /// The projects of the currently-loaded workspace (root seeded as default).
    public internal(set) var projects: [WorkspaceProjectsStore.ProjectRef] = []

    /// Resumable sessions per project path, lazily loaded on expand.
    public internal(set) var sessionsByProject: [String: [SessionSummary]] = [:]

    /// Per-project adapter capabilities resolved through `ProjectAgentRouter`
    /// (resumable sessions, session-handshake gate). Replaces parallel bool maps.
    public internal(set) var projectCapabilities = ProjectCapabilityIndex()

    /// Project paths whose session list is currently loading (drives skeletons).
    public internal(set) var loadingProjectPaths: Set<String> = []

    /// Transport-neutral gate: when the active adapter doesn't declare
    /// `.resumableSessions` (e.g. a direct-API / ACP agent), the navigator shows
    /// projects with New Chat only and no session rows. Set by the app shell
    /// from the adapter capabilities.
    public var supportsResumableSessions: Bool = true

    /// Agent-agnostic session lister, injected by the app shell (resolves the
    /// adapter via `AdapterRegistry` so `AgentUI` never imports a concrete
    /// adapter). Returns `[]` for agents without resumable sessions.
    public var sessionLister: (@Sendable (URL) async -> [SessionSummary])?

    /// Agent-agnostic Workspace→Projects store, injected by the app shell.
    public var workspaceProjects: WorkspaceProjectsStore?

    /// The just-removed project, surfaced as an undo toast until it expires.
    public internal(set) var removedProjectUndo: WorkspaceProjectsStore.RemovedProject?

    /// UUID of the last user-turn bubble, extracted from the engine event id.
    /// Used by the edit-and-resubmit affordance.
    public internal(set) var lastUserBubbleID: UUID?

    /// When non-nil, `PromptComposerView` should pre-fill its draft text and
    /// clear this field after consuming it.
    public var editDraft: String?

    /// Set when a `.snapshotReady` event arrives so the app shell can show a
    /// save panel. Cleared by the app after presenting.
    public internal(set) var pendingExport: PendingExport?

    /// Slash commands surfaced in the composer palette.
    /// Set by the app shell after a workspace opens (adapter catalog + project commands).
    public var slashCommands: [SlashCommand] = []

    /// Rolling tok/s estimate for the currently-streaming bubble.
    /// Non-nil only while streaming with ≥ 5 deltas and ≥ 1s elapsed.
    public internal(set) var tokenRatePerSecond: Double? = nil

    /// True for 8 seconds after a 90-second no-event gap fires the stalled toast.
    /// Single-fire per turn; reset on session start and on stop.
    public internal(set) var stalledToastVisible: Bool = false

    // MARK: - Cross-extension state (internal — split across +Conversation/+Navigator/+Send)

    var thinkingBlockTexts: [UUID: String] = [:]
    var deltaTimestamps: [Date] = []
    var streamingStartedAt: Date?
    var stalledToastTask: Task<Void, Never>?
    var removedProjectUndoTask: Task<Void, Never>?
    var sessionSwitchingTask: Task<Void, Never>?
    var composerResumeUnlockTask: Task<Void, Never>?
    var adapterCapabilitiesGeneration = 0
    var stalledToastFiredThisTurn = false
    var isAwaitingFirstReplyForPrompt = false
    var pendingOptimisticBubbleID: UUID?
    var dedupUserText: String?
    var dedupArmedAt: Date?
    var dedupDropsRemaining: Int = 0

    var echoWindowSeconds: TimeInterval {
        TimeInterval(ActivityTiming.userTurnEchoWindow.components.seconds)
    }

    public var canCancel: Bool {
        switch activity {
        case .idle, .waitingPermission: return false
        default: return true
        }
    }

    // MARK: - Engine binding

    public let engine: any AgentEngineCommandPort
    let bus: MulticastEventBus
    let clock: any AgentClock
    let random: any RandomSource
    private var subscriptionTask: Task<Void, Never>?

    public init(engine: any AgentEngineCommandPort,
                bus: MulticastEventBus,
                clock: any AgentClock = SystemClock(),
                random: any RandomSource = SystemRandomSource()) {
        self.engine = engine
        self.bus = bus
        self.clock = clock
        self.random = random
    }

    /// Begin observing the bus. Idempotent.
    public func subscribe() {
        guard subscriptionTask == nil else { return }
        subscriptionTask = Task { [weak self] in
            guard let self else { return }
            let sub = await self.bus.subscribe()
            for await entry in sub.stream {
                self.apply(entry.event)
                // Dense stdio bursts (ACP/Cursor) can deliver many chunks in one
                // MainActor turn; yield so SwiftUI can paint intermediate prose.
                switch entry.event {
                case .assistantText(_, _, _, false), .textDelta, .thinkingChunk:
                    await Task.yield()
                default:
                    break
                }
            }
        }
    }

    public func unsubscribe() {
        subscriptionTask?.cancel()
        subscriptionTask = nil
    }

    // No deinit — callers must call `unsubscribe()` on view-disappear, and
    // the task captures `[weak self]` so it ends naturally otherwise.

    /// Clears the pending export after the app shell has presented a save panel.
    public func clearPendingExport() { pendingExport = nil }

    #if DEBUG
    /// Seed navigator state directly for previews/tests (DEBUG only).
    func applyPreviewState(workspace: URL,
                           projects: [WorkspaceProjectsStore.ProjectRef],
                           sessions: [String: [SessionSummary]]) {
        self.workspaceRoot = workspace
        self.workspace = workspace
        self.projects = projects
        self.sessionsByProject = sessions
    }

    /// Seed conversation chrome for previews (DEBUG only).
    func applyPreviewConversationState() {
        messages = PreviewFixtures.conversationMessages()
        changedFiles = ["src/AgentUI/Sidebar/SessionSidebarView.swift"]
        sessionTokens = 12_400
        sessionCostUSD = 0.42
        status = .working(phrase: "Thinking…")
        activity = .streamingText
    }
    #endif

    /// Forward a typed command to the engine. Errors land in `diagnostics`.
    func send(_ command: AgentCommand) {
        Task { [engine] in
            do {
                try await engine.send(command)
            } catch let error as AgentError {
                await MainActor.run {
                    self.diagnostics.append(self.diagnostic(level: .error, message: error.userMessage))
                }
            } catch {
                await MainActor.run {
                    self.diagnostics.append(self.diagnostic(level: .error,
                                                            message: error.localizedDescription))
                }
            }
        }
    }

    public struct WorkspaceModelCatalogRow: Identifiable, Sendable, Hashable {
        public var id: AgentID { agentID }
        public let agentID: AgentID
        public let displayName: String
        public let refreshKind: ModelCatalogRefreshKind
        public let modelCount: Int
        public let refreshedAt: Date?

        public init(agentID: AgentID,
                    displayName: String,
                    refreshKind: ModelCatalogRefreshKind,
                    modelCount: Int,
                    refreshedAt: Date?) {
            self.agentID = agentID
            self.displayName = displayName
            self.refreshKind = refreshKind
            self.modelCount = modelCount
            self.refreshedAt = refreshedAt
        }
    }

    public enum ModelCatalogLoadError: Error, LocalizedError, Sendable {
        case adapterUnavailable(AgentID)
        case emptyCatalog(String)

        public var errorDescription: String? {
            switch self {
            case .adapterUnavailable(let id):
                return "No adapter is registered for \(id.rawValue)."
            case .emptyCatalog(let name):
                return "\(name) returned no models. Check that the CLI is installed and authenticated."
            }
        }
    }
}

// MARK: - View-model value types

public extension EngineViewModel {

    enum Message: Sendable, Hashable, Identifiable {
        /// A user-composed prompt.  `bubbleID` is stable across updates.
        case user(bubbleID: UUID, text: String)
        /// A fully-settled assistant response.
        case assistant(bubbleID: UUID, text: String)
        /// A response still receiving deltas.  Same `bubbleID` as the final `.assistant`
        /// so SwiftUI's `ForEach` never recreates the view mid-stream.
        case assistantStreaming(bubbleID: UUID, text: String)
        case thinkingChunk(blockID: UUID, delta: String)
        case thinkingComplete(blockID: UUID, text: String, duration: Duration)
        /// An ordering marker for a tool call. The card content is read live
        /// from `activeToolCalls` by `callID`, so the entry can keep mutating
        /// (progress, completion) while its position in the turn stays fixed.
        case toolCall(callID: String)
        /// Codemixer-owned history marker for an agent-affecting client intent
        /// (mode, slash, permission). Live session + export only.
        case clientAction(ClientAction)

        public var id: String {
            switch self {
            case .user(let id, _):              return "user-\(id)"
            // Streaming and settled assistant share one id so ForEach morphs the
            // bubble in place instead of tearing it down on finalize (which made
            // replies look like they arrived all at once).
            case .assistant(let id, _), .assistantStreaming(let id, _):
                return "asst-\(id)"
            // Both thinking states share one id per block so the row morphs in
            // place (streaming → collapsed "Thought for Xs") instead of being
            // torn down and rebuilt.
            case .thinkingChunk(let id, _):     return "thinking-\(id)"
            case .thinkingComplete(let id, _, _):  return "thinking-\(id)"
            case .toolCall(let id):             return "tool-\(id)"
            case .clientAction(let action):     return "action-\(action.id)"
            }
        }

        /// Plaintext content (nil for completed-thinking and tool bubbles).
        public var textContent: String? {
            switch self {
            case .user(_, let t), .assistant(_, let t), .assistantStreaming(_, let t): return t
            case .thinkingChunk(_, let t): return t
            case .thinkingComplete(_, let t, _): return t
            case .toolCall: return nil
            case .clientAction(let action):
                return action.detail.map { "\(action.title): \($0)" } ?? action.title
            }
        }
    }

    struct ToolCallEntry: Sendable, Hashable, Identifiable {
        public let id: String
        public let name: String
        public let input: ToolInput
        public var finished: Bool
        public var success: Bool = true
        public var output: ToolOutput?
        public var progress: ToolProgress?
        /// Accumulated subagent output lines (one per `.toolProgress(.generic)` event
        /// keyed to this call's ID). Rendered as a nested mini-conversation inside the card.
        public var subagentLines: [String] = []
    }

    struct DiagnosticEntry: Sendable, Hashable, Identifiable {
        public enum Level: Sendable, Hashable { case info, warning, error }
        public let id: UUID
        public let level: Level
        public let message: String
    }

    enum StatusLine: Sendable, Equatable {
        case idle
        case working(phrase: String)
    }

    /// Payload surfaced by a `.snapshotReady` event so the app shell can
    /// present a save panel. The app clears `model.pendingExport` after use.
    struct PendingExport: Sendable {
        public let kind: SnapshotKind
        public let payload: Data
    }

    /// Per-project adapter capability snapshot resolved for the navigator.
    struct ProjectCapabilities: Sendable, Hashable {
        var supportsResumableSessions: Bool
        var requiresSessionHandshakeGate: Bool
        var supportsOverviewDashboard: Bool

        init(supportsResumableSessions: Bool,
             requiresSessionHandshakeGate: Bool,
             supportsOverviewDashboard: Bool = false) {
            self.supportsResumableSessions = supportsResumableSessions
            self.requiresSessionHandshakeGate = requiresSessionHandshakeGate
            self.supportsOverviewDashboard = supportsOverviewDashboard
        }

        static let none = ProjectCapabilities(
            supportsResumableSessions: false,
            requiresSessionHandshakeGate: false,
            supportsOverviewDashboard: false
        )
    }

    /// Path-keyed index of `ProjectCapabilities`. Lookups tolerate path
    /// standardization differences between store paths and UI paths.
    struct ProjectCapabilityIndex: Sendable {
        private var entries: [String: ProjectCapabilities] = [:]

        var isEmpty: Bool { entries.isEmpty }

        var anySupportsResumableSessions: Bool {
            entries.values.contains { $0.supportsResumableSessions }
        }

        subscript(_ path: String) -> ProjectCapabilities? {
            get { entry(for: path) }
            set {
                let key = Self.normalized(path)
                if let newValue {
                    entries[key] = newValue
                } else {
                    entries.removeValue(forKey: key)
                }
            }
        }

        mutating func removeAll() {
            entries.removeAll(keepingCapacity: false)
        }

        mutating func rekey(from oldPath: String, to newPath: String) {
            guard oldPath != newPath,
                  let value = removeEntry(for: oldPath),
                  entry(for: newPath) == nil else { return }
            entries[Self.normalized(newPath)] = value
        }

        func supportsResumableSessions(for path: String) -> Bool? {
            entry(for: path)?.supportsResumableSessions
        }

        func requiresSessionHandshakeGate(for path: String) -> Bool {
            entry(for: path)?.requiresSessionHandshakeGate ?? false
        }

        private func entry(for path: String) -> ProjectCapabilities? {
            let normalized = Self.normalized(path)
            if let exact = entries[path] { return exact }
            if let cached = entries[normalized] { return cached }
            for (key, value) in entries where Self.normalized(key) == normalized {
                return value
            }
            return nil
        }

        private mutating func removeEntry(for path: String) -> ProjectCapabilities? {
            let normalized = Self.normalized(path)
            if let value = entries.removeValue(forKey: path) { return value }
            if let value = entries.removeValue(forKey: normalized) { return value }
            if let key = entries.keys.first(where: { Self.normalized($0) == normalized }) {
                return entries.removeValue(forKey: key)
            }
            return nil
        }

        private static func normalized(_ path: String) -> String {
            URL(fileURLWithPath: path).standardizedFileURL.path
        }
    }
}
