import Foundation
import Observation
import SwiftUI
import AgentCore
import AgentProtocol

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
    /// Active project cwd from the agent session (conversation / diff / composer).
    public internal(set) var workspace: URL?
    /// Loaded workspace folder (one per window). Owns the projects list in the
    /// sidebar; distinct from `workspace`, which tracks the active project cwd.
    /// Set by the app shell when adopting / opening / closing a workspace.
    public var workspaceRoot: URL?
    public internal(set) var messages: [Message] = []
    public internal(set) var activeToolCalls: [ToolCallEntry] = []
    public internal(set) var pendingPermission: PermissionPrompt?
    public internal(set) var diagnostics: [DiagnosticEntry] = []
    public internal(set) var status: StatusLine = .idle
    public internal(set) var activity: ActivitySubstate = .idle
    public internal(set) var changedFiles: [String] = []
    /// WebSocket peers attached to `RemoteControlServer` (server-side count).
    /// In Mode B includes the loopback GUI; in Mode A counts external peers only.
    /// See `docs/architecture.md` §4.1 and `Remote/AgentRemoteControl/README.md`.
    public internal(set) var connectedRemoteClients: Int = 0
    public internal(set) var isSwitchingSession: Bool = false
    public internal(set) var sessionTokens: Int = 0
    public internal(set) var sessionCostUSD: Double?
    public internal(set) var appearancePrefs: AppearancePrefs = .init()
    public internal(set) var autoApprovalRules: [AutoApprovalRule] = []
    public var availableModels: [AgentModelOption] = []

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

    /// Whether the session navigator rail is shown. GUI chrome only — persisted
    /// via `AppearancePrefs`, never on the wire.
    public var sidebarVisible: Bool = true

    /// The projects of the currently-loaded workspace (root seeded as default).
    public internal(set) var projects: [WorkspaceProjectsStore.ProjectRef] = []

    /// Resumable sessions per project path, lazily loaded on expand.
    public internal(set) var sessionsByProject: [String: [SessionSummary]] = [:]

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
    public func send(_ command: AgentCommand) {
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

        public var id: String {
            switch self {
            case .user(let id, _):              return "user-\(id)"
            case .assistant(let id, _):         return "asst-\(id)"
            case .assistantStreaming(let id, _): return "stream-\(id)"
            // Both thinking states share one id per block so the row morphs in
            // place (streaming → collapsed "Thought for Xs") instead of being
            // torn down and rebuilt.
            case .thinkingChunk(let id, _):     return "thinking-\(id)"
            case .thinkingComplete(let id, _, _):  return "thinking-\(id)"
            case .toolCall(let id):             return "tool-\(id)"
            }
        }

        /// Plaintext content (nil for completed-thinking and tool bubbles).
        public var textContent: String? {
            switch self {
            case .user(_, let t), .assistant(_, let t), .assistantStreaming(_, let t): return t
            case .thinkingChunk(_, let t): return t
            case .thinkingComplete(_, let t, _): return t
            case .toolCall: return nil
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
}
