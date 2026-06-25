import Foundation
import Observation
import SwiftUI
import AgentCore
import AgentProtocol

private enum SessionSwitchingTiming {
    static let emptySessionFallback: Duration = .seconds(2)
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

    public private(set) var sessionID: String?
    public private(set) var workspace: URL?
    public private(set) var messages: [Message] = []
    public private(set) var activeToolCalls: [ToolCallEntry] = []
    public private(set) var pendingPermission: PermissionPrompt?
    public private(set) var diagnostics: [DiagnosticEntry] = []
    public private(set) var status: StatusLine = .idle
    public private(set) var activity: ActivitySubstate = .idle
    public private(set) var changedFiles: [String] = []
    public private(set) var connectedRemoteClients: Int = 0
    public private(set) var isSwitchingSession: Bool = false
    public private(set) var sessionTokens: Int = 0
    public private(set) var sessionCostUSD: Double?
    public private(set) var appearancePrefs: AppearancePrefs = .init()
    public private(set) var autoApprovalRules: [AutoApprovalRule] = []

    public var showUsageChip: Bool { appearancePrefs.showUsageChip }

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
    public private(set) var projects: [WorkspaceProjectsStore.ProjectRef] = []

    /// Resumable sessions per project path, lazily loaded on expand.
    public private(set) var sessionsByProject: [String: [SessionSummary]] = [:]

    /// Project paths whose session list is currently loading (drives skeletons).
    public private(set) var loadingProjectPaths: Set<String> = []

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
    public private(set) var removedProjectUndo: WorkspaceProjectsStore.RemovedProject?

    /// UUID of the last user-turn bubble, extracted from the engine event id.
    /// Used by the edit-and-resubmit affordance.
    public private(set) var lastUserBubbleID: UUID?

    /// When non-nil, `PromptComposerView` should pre-fill its draft text and
    /// clear this field after consuming it.
    public var editDraft: String?

    /// Set when a `.snapshotReady` event arrives so the app shell can show a
    /// save panel. Cleared by the app after presenting.
    public private(set) var pendingExport: PendingExport?

    /// Slash commands surfaced in the composer palette.
    /// Set by the app shell after a workspace opens (adapter catalog + project commands).
    public var slashCommands: [SlashCommand] = []

    /// Rolling tok/s estimate for the currently-streaming bubble.
    /// Non-nil only while streaming with ≥ 5 deltas and ≥ 1s elapsed.
    public private(set) var tokenRatePerSecond: Double? = nil

    /// True for 8 seconds after a 90-second no-event gap fires the stalled toast.
    /// Single-fire per turn; reset on session start and on stop.
    public private(set) var stalledToastVisible: Bool = false

    // Thinking-block accumulation: keyed by blockID, value is accumulated text.
    private var thinkingBlockTexts: [UUID: String] = [:]

    // Token rate tracking (UI-side estimation, main-actor only).
    private var deltaTimestamps: [Date] = []          // timestamps of last 5 deltas
    private var streamingStartedAt: Date?             // when the first delta for this bubble arrived

    // Stalled toast lifecycle.
    private var stalledToastTask: Task<Void, Never>?
    private var removedProjectUndoTask: Task<Void, Never>?
    private var sessionSwitchingTask: Task<Void, Never>?
    private var stalledToastFiredThisTurn = false

    // Optimistic-send reconciliation.
    //
    // `.userTurn` has TWO publishers — `AgentEngine.sendPrompt` and the Claude
    // `UserPromptSubmit` hook (different ids) — so a naive `apply(.userTurn)`
    // would render the bubble twice. With optimistic send we also pre-insert
    // the bubble locally. These fields collapse all of that into one bubble:
    // the first matching echo adopts the engine id onto the optimistic bubble,
    // and a bounded number of further matching echoes within a short window are
    // dropped as duplicates.
    private var pendingOptimisticBubbleID: UUID?
    private var dedupUserText: String?
    private var dedupArmedAt: Date?
    private var dedupDropsRemaining: Int = 0

    /// Echo-dedup window in seconds, sourced from the single `ActivityTiming`
    /// constant (`Duration` → seconds).
    private var echoWindowSeconds: TimeInterval {
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
    private let bus: MulticastEventBus
    private let clock: any AgentClock
    private let random: any RandomSource
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
            for await event in sub.stream {
                self.apply(event)
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
        self.workspace = workspace
        self.projects = projects
        self.sessionsByProject = sessions
    }
    #endif

    // MARK: - Private helpers

    /// Compute a rolling tok/s estimate from the last 5 delta timestamps.
    /// Shown only when ≥ 5 deltas and ≥ 1s of streaming have elapsed.
    private func updateTokenRate() {
        let now = clock.now()
        deltaTimestamps.append(now)
        if deltaTimestamps.count > 5 { deltaTimestamps.removeFirst() }

        guard deltaTimestamps.count >= 5,
              let start = streamingStartedAt,
              now.timeIntervalSince(start) >= 1.0,
              let first = deltaTimestamps.first else {
            tokenRatePerSecond = nil
            return
        }
        let windowSeconds = now.timeIntervalSince(first)
        if windowSeconds > 0 {
            tokenRatePerSecond = Double(deltaTimestamps.count - 1) / windowSeconds
        }
    }

    private func diagnostic(level: DiagnosticEntry.Level,
                            message: String) -> DiagnosticEntry {
        DiagnosticEntry(id: random.uuid(), level: level, message: message)
    }

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

    // MARK: - Optimistic send

    /// Send a prompt with instant local feedback: append the user bubble and
    /// flip to a working state on the main actor *before* the engine round-trip,
    /// then reconcile when the engine (and the Claude hook) echo `.userTurn`.
    /// Rolls the optimistic bubble back if the send throws.
    ///
    /// Prefer this over `send(.sendPrompt(...))` from the UI so sending never
    /// waits on the PTY write + bus fan-out (visual-style §1.6).
    public func sendPrompt(_ text: String, attachments: [AttachmentRef] = []) {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }

        let bubbleID = random.uuid()
        messages.append(.user(bubbleID: bubbleID, text: trimmed))
        lastUserBubbleID = bubbleID
        pendingOptimisticBubbleID = bubbleID
        armEchoDedup(for: trimmed)
        enterWorkingState()

        Task { [engine, weak self] in
            do {
                try await engine.send(.sendPrompt(text: text, attachments: attachments))
            } catch {
                await MainActor.run { self?.rollBackOptimisticSend(bubbleID: bubbleID, error: error) }
            }
        }
    }

    /// Edit-and-resubmit restarts the session (which clears `messages` and
    /// replays the truncated transcript), so we don't pre-insert a bubble —
    /// the genuine `.userTurn` carries the revised text. We only flip to a
    /// working state immediately for instant feedback, and let the echo dedup
    /// collapse the engine + hook duplicates.
    public func editAndResubmit(targetBubbleID: UUID,
                                text: String,
                                attachments: [AttachmentRef] = []) {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        enterWorkingState()
        send(.editAndResubmitLast(targetBubbleID: targetBubbleID,
                                  text: text,
                                  attachments: attachments))
    }

    private func enterWorkingState() {
        status = .working(phrase: ActivityTiming.workingPhrase)
        activity = .awaitingFirstChunk
    }

    /// Arm duplicate detection for a just-sent/materialised user turn. We expect
    /// exactly one further echo (the Claude hook) beyond the one that creates
    /// the bubble, so `dedupDropsRemaining` is 1.
    private func armEchoDedup(for trimmed: String) {
        dedupUserText = trimmed
        dedupArmedAt = clock.now()
        dedupDropsRemaining = 1
    }

    private func rollBackOptimisticSend(bubbleID: UUID, error: any Error) {
        if pendingOptimisticBubbleID == bubbleID {
            messages.removeAll {
                if case .user(let b, _) = $0 { return b == bubbleID }
                return false
            }
            pendingOptimisticBubbleID = nil
            dedupUserText = nil
            dedupArmedAt = nil
            dedupDropsRemaining = 0
            lastUserBubbleID = lastUserBubbleIDInMessages()
            status = .idle
            activity = .idle
        }
        let message = (error as? AgentError)?.userMessage ?? error.localizedDescription
        diagnostics.append(diagnostic(level: .error, message: message))
    }

    private func lastUserBubbleIDInMessages() -> UUID? {
        for message in messages.reversed() {
            if case .user(let id, _) = message { return id }
        }
        return nil
    }

    // MARK: - Session navigator actions

    /// Reload the projects for the current workspace, seeding the root project.
    public func refreshProjects() {
        guard let workspace, let store = workspaceProjects else { return }
        Task { [weak self] in
            let refs = await store.projects(for: workspace)
            await MainActor.run { self?.projects = refs }
        }
    }

    /// Lazily list the resumable sessions for a project. A non-resumable agent
    /// (or an empty result) is a first-class empty state, not an error.
    /// Subsequent refreshes update the list silently (no skeleton) so the
    /// navigator doesn't flash on every session switch.
    public func loadSessions(for projectPath: String) {
        guard supportsResumableSessions, let lister = sessionLister else {
            sessionsByProject[projectPath] = []
            return
        }
        // Only show the skeleton placeholder on the very first load.
        // Re-loads keep the stale list visible until fresh data arrives.
        if sessionsByProject[projectPath] == nil {
            loadingProjectPaths.insert(projectPath)
        }
        let url = URL(fileURLWithPath: projectPath)
        Task { [weak self] in
            let sessions = await lister(url)
            await MainActor.run {
                self?.sessionsByProject[projectPath] = sessions
                self?.loadingProjectPaths.remove(projectPath)
            }
        }
    }

    /// Open a specific resumable session of a project.
    public func openSession(projectPath: String, id: String) {
        guard !isCurrentSession(projectPath: projectPath, sessionID: id) else { return }
        beginSessionSwitch(projectPath: projectPath, sessionID: id)
        send(.openProject(path: projectPath, resumeSessionID: id))
    }

    /// Start a fresh chat. For the active project this is `.newSession`; for
    /// another project it reopens that project with no resume id. Both reuse
    /// existing wire commands, so remote clients reach the same behavior.
    public func newChat(in projectPath: String) {
        endSessionSwitch()
        if projectPath == workspace?.path {
            send(.newSession)
        } else {
            send(.openProject(path: projectPath, resumeSessionID: nil))
        }
    }

    /// Create a new project (subfolder of the workspace) and switch to it.
    public func createProject(name: String) {
        guard let workspace, let store = workspaceProjects else { return }
        Task { [weak self] in
            do {
                let ref = try await store.createProject(name: name, in: workspace)
                let refs = await store.projects(for: workspace)
                await MainActor.run {
                    self?.projects = refs
                    self?.newChat(in: ref.path)
                }
            } catch {
                await MainActor.run { self?.recordProjectError(error) }
            }
        }
    }

    /// Register an existing folder as a project of the workspace.
    public func addExistingProject(url: URL) {
        guard let workspace, let store = workspaceProjects else { return }
        Task { [weak self] in
            do {
                let ref = try await store.addExistingProject(url: url, in: workspace)
                let refs = await store.projects(for: workspace)
                await MainActor.run {
                    self?.projects = refs
                    self?.newChat(in: ref.path)
                }
            } catch {
                await MainActor.run { self?.recordProjectError(error) }
            }
        }
    }

    /// Rename a project's display label (folder on disk is untouched).
    public func renameProject(path: String, newName: String) {
        guard let workspace, let store = workspaceProjects else { return }
        Task { [weak self] in
            do {
                try await store.renameProject(path: path, to: newName, in: workspace)
                let refs = await store.projects(for: workspace)
                await MainActor.run { self?.projects = refs }
            } catch {
                await MainActor.run { self?.recordProjectError(error) }
            }
        }
    }

    /// Remove a project from the navigator (never deletes the folder) and arm an
    /// undo toast. The seeded root cannot be removed.
    public func removeProject(path: String) {
        guard let workspace, let store = workspaceProjects else { return }
        Task { [weak self] in
            do {
                let removed = try await store.removeProject(path: path, in: workspace)
                let refs = await store.projects(for: workspace)
                await MainActor.run {
                    self?.projects = refs
                    if let removed { self?.armRemovedProjectUndo(removed) }
                }
            } catch {
                await MainActor.run { self?.recordProjectError(error) }
            }
        }
    }

    /// Restore the most recently removed project at its former position.
    public func undoRemoveProject() {
        guard let workspace, let store = workspaceProjects,
              let removed = removedProjectUndo else { return }
        removedProjectUndoTask?.cancel()
        removedProjectUndoTask = nil
        removedProjectUndo = nil
        Task { [weak self] in
            do {
                try await store.restoreProject(removed, in: workspace)
                let refs = await store.projects(for: workspace)
                await MainActor.run { self?.projects = refs }
            } catch {
                await MainActor.run { self?.recordProjectError(error) }
            }
        }
    }

    private func armRemovedProjectUndo(_ removed: WorkspaceProjectsStore.RemovedProject) {
        removedProjectUndoTask?.cancel()
        removedProjectUndo = removed
        removedProjectUndoTask = Task { [weak self] in
            try? await self?.clock.sleep(for: ActivityTiming.undoToastWindow)
            await MainActor.run { self?.removedProjectUndo = nil }
        }
    }

    private func beginSessionSwitch(projectPath: String, sessionID id: String) {
        workspace = URL(fileURLWithPath: projectPath)
        sessionID = id
        clearConversationState()
        isSwitchingSession = true
        sessionSwitchingTask?.cancel()
        sessionSwitchingTask = Task { [weak self] in
            try? await self?.clock.sleep(for: SessionSwitchingTiming.emptySessionFallback)
            await MainActor.run {
                guard let self,
                      self.messages.isEmpty,
                      self.activeToolCalls.isEmpty else { return }
                self.isSwitchingSession = false
                self.sessionSwitchingTask = nil
            }
        }
    }

    private func endSessionSwitch() {
        isSwitchingSession = false
        sessionSwitchingTask?.cancel()
        sessionSwitchingTask = nil
    }

    private func finishSessionSwitchIfNeeded() {
        if isSwitchingSession {
            endSessionSwitch()
        }
    }

    private func settleTurnIdle() {
        activity = .idle
        status = .idle
        tokenRatePerSecond = nil
        deltaTimestamps.removeAll()
        streamingStartedAt = nil
        stalledToastFiredThisTurn = false
        stalledToastTask?.cancel()
        stalledToastTask = nil
        stalledToastVisible = false
    }

    private func clearConversationState() {
        messages = []
        activeToolCalls = []
        lastUserBubbleID = nil
        thinkingBlockTexts.removeAll()
        deltaTimestamps.removeAll()
        streamingStartedAt = nil
        tokenRatePerSecond = nil
        stalledToastFiredThisTurn = false
        stalledToastTask?.cancel()
        stalledToastTask = nil
        stalledToastVisible = false
        pendingOptimisticBubbleID = nil
        dedupUserText = nil
        dedupArmedAt = nil
        dedupDropsRemaining = 0
    }

    /// True when `session` is the one currently displayed in the conversation.
    public func isCurrentSession(projectPath: String, sessionID id: String) -> Bool {
        workspace?.path == projectPath && sessionID == id
    }

    private func recordProjectError(_ error: any Error) {
        let message = (error as? AgentError)?.userMessage ?? error.localizedDescription
        diagnostics.append(diagnostic(level: .error, message: message))
    }

    private func displayPath(forTouchedFile url: URL) -> String {
        guard let workspace else { return url.path }
        let workspacePaths = [workspace, workspace.resolvingSymlinksInPath()]
            .map { $0.path.hasSuffix("/") ? $0.path : $0.path + "/" }
        let filePath = url.path
        let resolvedFilePath = url.resolvingSymlinksInPath().path
        for root in workspacePaths {
            if filePath.hasPrefix(root) {
                return String(filePath.dropFirst(root.count))
            }
            if resolvedFilePath.hasPrefix(root) {
                return String(resolvedFilePath.dropFirst(root.count))
            }
        }
        return filePath
    }

    /// Called when the active workspace changes: refresh projects + load the
    /// active project's sessions so the navigator reflects the new state.
    private func onWorkspaceChanged() {
        refreshProjects()
        if let workspace { loadSessions(for: workspace.path) }
    }

    /// Reconcile a `.userTurn` echo against any optimistic bubble + duplicate
    /// hook echo. See `pendingOptimisticBubbleID` for the full rationale.
    private func applyUserTurn(id: String, text: String) {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        let now = clock.now()
        let withinWindow = (dedupArmedAt.map { now.timeIntervalSince($0) <= echoWindowSeconds }) ?? false

        if dedupUserText == trimmed, withinWindow {
            if let optimisticID = pendingOptimisticBubbleID {
                // First real echo for an optimistic bubble: adopt the engine id
                // so edit-and-resubmit targets the right turn.
                let adoptedID = UUID(uuidString: id) ?? optimisticID
                if let idx = messages.lastIndex(where: {
                    if case .user(let b, _) = $0 { return b == optimisticID }
                    return false
                }) {
                    messages[idx] = .user(bubbleID: adoptedID, text: text)
                }
                lastUserBubbleID = adoptedID
                pendingOptimisticBubbleID = nil
                // Re-arm the window so the later hook echo still drops.
                dedupArmedAt = now
                return
            }
            if dedupDropsRemaining > 0 {
                dedupDropsRemaining -= 1
                return  // duplicate (engine + hook double-publish) — drop.
            }
        }

        // Genuine new user turn.
        let uid = UUID(uuidString: id) ?? random.uuid()
        messages.append(.user(bubbleID: uid, text: text))
        lastUserBubbleID = uid
        pendingOptimisticBubbleID = nil
        armEchoDedup(for: trimmed)
    }

    // MARK: - Event reduction

    private func apply(_ event: AgentEvent) {
        switch event {
        case .sessionStarted(let id, _, let cwd):
            let workspaceChanged = workspace?.path != cwd.path
            let sessionChanged = sessionID != id
            let shouldResetConversation = workspaceChanged || (sessionChanged && activity == .idle)
            sessionID = id
            workspace = cwd
            if shouldResetConversation {
                clearConversationState()
            }
            if workspaceChanged {
                onWorkspaceChanged()
            }
        case .userTurn(let id, let text):
            finishSessionSwitchIfNeeded()
            applyUserTurn(id: id, text: text)
        case .assistantText(let msgID, _, let text, let isFinal):
            finishSessionSwitchIfNeeded()
            // If there is an in-progress streaming bubble, update or promote it.
            // Promoting (isFinal = true) replaces the .assistantStreaming with
            // .assistant so the bubble ID stays the same and SwiftUI keeps the view.
            if let lastIdx = messages.indices.last,
               case .assistantStreaming(let existingID, _) = messages[lastIdx] {
                messages[lastIdx] = isFinal
                    ? .assistant(bubbleID: existingID, text: text)
                    : .assistantStreaming(bubbleID: existingID, text: text)
            } else {
                let id = UUID(uuidString: msgID) ?? random.uuid()
                messages.append(isFinal
                    ? .assistant(bubbleID: id, text: text)
                    : .assistantStreaming(bubbleID: id, text: text))
            }
            if isFinal {
                settleTurnIdle()
            }
        case .textDelta(let messageID, let delta):
            finishSessionSwitchIfNeeded()
            if let lastIdx = messages.indices.last,
               case .assistantStreaming(let existingID, let existingText) = messages[lastIdx] {
                // Preserve the stable bubbleID; only the text grows.
                messages[lastIdx] = .assistantStreaming(bubbleID: existingID,
                                                        text: existingText + delta)
            } else {
                messages.append(.assistantStreaming(bubbleID: messageID, text: delta))
                streamingStartedAt = clock.now()
                deltaTimestamps.removeAll()
            }
            updateTokenRate()
        case .thinkingChunk(let blockID, let delta):
            finishSessionSwitchIfNeeded()
            // Accumulate chunks into a single message rather than appending one per chunk.
            let accumulated = (thinkingBlockTexts[blockID] ?? "") + delta
            thinkingBlockTexts[blockID] = accumulated
            if let idx = messages.lastIndex(where: {
                if case .thinkingChunk(let id, _) = $0 { return id == blockID }; return false
            }) {
                messages[idx] = .thinkingChunk(blockID: blockID, delta: accumulated)
            } else {
                messages.append(.thinkingChunk(blockID: blockID, delta: accumulated))
            }
        case .thinkingComplete(let blockID, let duration):
            finishSessionSwitchIfNeeded()
            let text = thinkingBlockTexts.removeValue(forKey: blockID) ?? ""
            if let idx = messages.lastIndex(where: {
                if case .thinkingChunk(let id, _) = $0 { return id == blockID }; return false
            }) {
                messages[idx] = .thinkingComplete(blockID: blockID, text: text, duration: duration)
            } else {
                messages.append(.thinkingComplete(blockID: blockID, text: text, duration: duration))
            }
        case .toolStart(let id, let name, let input, _):
            finishSessionSwitchIfNeeded()
            activeToolCalls.append(ToolCallEntry(id: id, name: name, input: input, finished: false))
            // Drop an ordering marker into the message stream so the card renders
            // inline at the point the tool actually ran, between assistant prose.
            if !messages.contains(where: { if case .toolCall(let c) = $0 { return c == id }; return false }) {
                messages.append(.toolCall(callID: id))
            }
        case .toolEnd(let id, let success, let output, _):
            finishSessionSwitchIfNeeded()
            if let idx = activeToolCalls.firstIndex(where: { $0.id == id }) {
                activeToolCalls[idx].finished = true
                activeToolCalls[idx].success = success
                activeToolCalls[idx].output = output
            }
        case .permissionRequest(let prompt):
            pendingPermission = prompt
            activity = .waitingPermission
        case .permissionAlreadyResolved:
            pendingPermission = nil
        case .statusPhraseChanged(_, let phrase):
            status = .working(phrase: phrase)
        case .activityStateChanged(let substate):
            activity = substate
            if substate == .idle { settleTurnIdle() }
        case .noEventGap(_, let elapsed):
            if activity != .idle {
                if elapsed > ActivityTiming.stillWorkingThreshold {
                    status = .working(phrase: ActivityTiming.stillWorkingPhrase)
                }
                if elapsed > ActivityTiming.probablyStuckThreshold && !stalledToastFiredThisTurn {
                    stalledToastFiredThisTurn = true
                    stalledToastVisible = true
                    stalledToastTask?.cancel()
                    stalledToastTask = nil
                }
            }
        case .fileTouched(let url, _):
            let rel = displayPath(forTouchedFile: url)
            if !changedFiles.contains(rel) { changedFiles.append(rel) }
        case .stopped:
            if !isSwitchingSession {
                endSessionSwitch()
            }
            settleTurnIdle()
        case .error(let error):
            endSessionSwitch()
            diagnostics.append(diagnostic(level: .error, message: error.userMessage))
        case .authURL:
            // Routed elsewhere — AuthGateView will pick this up.
            break
        case .bell, .engineRestarted:
            break
        case .usage(let tokens, let cost):
            sessionTokens = tokens
            sessionCostUSD = cost
        case .toolProgress(let callID, let progress):
            finishSessionSwitchIfNeeded()
            if let idx = activeToolCalls.firstIndex(where: { $0.id == callID.uuidString }) {
                activeToolCalls[idx].progress = progress
                // Subagent text surfaces as .generic — accumulate it as nested lines.
                if case .generic(let msg) = progress {
                    activeToolCalls[idx].subagentLines.append(msg)
                }
            }
        case .speakBubbleRequested:
            break
        case .fileReverted(let path):
            changedFiles.removeAll { $0 == path }
        case .prefsChanged(let count):
            diagnostics.append(diagnostic(level: .info, message: "Auto-approval rules updated (\(count))."))
        case .appearancePrefChanged(let key, let value):
            appearancePrefs.update(key, value)
            if key == .sidebarVisible, case .bool(let visible) = value {
                sidebarVisible = visible
            }
        case .snapshotReady(let kind, let payload):
            pendingExport = PendingExport(kind: kind, payload: payload)
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
