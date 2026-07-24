import Foundation

import AgentCore
import AgentProtocol

/// Synchronous session state shared by Codex encoders and the async decoder.
///
/// `AgentAdapter` input-encoding requirements are synchronous, while response
/// decoding is asynchronous. A small lock-protected store bridges those two
/// surfaces without exposing mutable state across executors.
///
/// Safety: every mutable property is accessed only while `lock` is held.
public final class CodexSessionState: @unchecked Sendable {
    struct Context: Sendable {
        let workspace: URL
        let permissionMode: PermissionMode
    }

    enum RequestPurpose: Sendable, Hashable {
        case initialize
        case threadStart
        case threadResume
        case turnStart(title: String?)
        case compact
        case review
        case other(String)
    }

    struct PendingApproval: Sendable, Hashable {
        let requestID: JSONValue
        let signature: String
    }

    /// Thread lifecycle relative to App Server `thread/start` / `thread/resume`.
    /// Prompts that arrive before the thread id is known accumulate in
    /// `.awaitingThread`; `activateThread(id:)` moves to `.active` and returns
    /// those queued batches so the caller can flush `turn/start` frames without
    /// dropping them.
    enum ThreadPhase: Sendable, Hashable {
        case awaitingThread(queued: [[CodexUserInput]])
        case active(threadID: String)
    }

    /// Whether a turn is in flight and, if so, which thread it belongs to.
    /// The thread id is captured at `beginTurn` time from `ThreadPhase.active`
    /// (a thread's id never changes without also clearing the turn).
    enum TurnPhase: Sendable, Hashable {
        case idle
        case active(turnID: String, threadID: String)
    }

    private let lock = NSLock()
    private var nextID = 1
    private var requests: [JSONValue: RequestPurpose] = [:]
    private var context: Context?
    private var threadPhase: ThreadPhase = .awaitingThread(queued: [])
    private var turnPhase: TurnPhase = .idle
    private var pendingApprovals: [UUID: PendingApproval] = [:]
    private var autoApprovalSignatures: Set<String> = []
    private var itemIDs: [String: UUID] = [:]
    private var itemStartedAt: [String: Date] = [:]
    private var assistantTextByItemID: [String: String] = [:]
    private var selectedModelCodeStorage: String?
    private var selectedThinkingEffortStorage: String?

    public init() {}

    func beginSession(context: LaunchContext) {
        withLock {
            self.context = Context(
                workspace: context.workspace,
                permissionMode: context.permissionMode
            )
            nextID = 1
            requests.removeAll()
            threadPhase = .awaitingThread(queued: [])
            turnPhase = .idle
            pendingApprovals.removeAll()
            autoApprovalSignatures.removeAll()
            itemIDs.removeAll()
            itemStartedAt.removeAll()
            assistantTextByItemID.removeAll()
            selectedModelCodeStorage = nil
            selectedThinkingEffortStorage = nil
        }
    }

    func nextRequestID(for purpose: RequestPurpose) -> JSONValue {
        withLock {
            let id = JSONValue.number(Double(nextID))
            nextID += 1
            requests[id] = purpose
            return id
        }
    }

    func takePurpose(for id: JSONValue) -> RequestPurpose? {
        withLock { requests.removeValue(forKey: id) }
    }

    func currentContext() -> Context? {
        withLock { context }
    }

    /// Activates the thread and returns any prompt batches queued while
    /// awaiting `thread/start` / `thread/resume`. Callers must flush those
    /// batches as `turn/start` frames (see `CodexInputEncoding.queuedTurns`).
    @discardableResult
    func activateThread(id: String) -> [[CodexUserInput]] {
        withLock {
            let queued: [[CodexUserInput]]
            if case .awaitingThread(let pending) = threadPhase {
                queued = pending
            } else {
                queued = []
            }
            threadPhase = .active(threadID: id)
            return queued
        }
    }

    func prepareNewThread() {
        withLock {
            requests.removeAll()
            threadPhase = .awaitingThread(queued: [])
            turnPhase = .idle
            pendingApprovals.removeAll()
            autoApprovalSignatures.removeAll()
            itemIDs.removeAll()
            itemStartedAt.removeAll()
            assistantTextByItemID.removeAll()
        }
    }

    func threadID() -> String? {
        withLock {
            if case .active(let threadID) = threadPhase { return threadID }
            return nil
        }
    }

    /// No-ops if no thread is active yet — this never happens over the real
    /// App Server wire (turn/start always follows a completed thread/start).
    func beginTurn(_ id: String) {
        withLock {
            guard case .active(let threadID) = threadPhase else { return }
            turnPhase = .active(turnID: id, threadID: threadID)
        }
    }

    func completeTurn(_ id: String?) {
        withLock {
            guard case .active(let turnID, _) = turnPhase,
                  id == nil || turnID == id else { return }
            turnPhase = .idle
        }
    }

    func activeTurn() -> (threadID: String, turnID: String)? {
        withLock {
            guard case .active(let turnID, let threadID) = turnPhase else { return nil }
            return (threadID, turnID)
        }
    }

    func enqueue(_ inputs: [CodexUserInput]) {
        withLock {
            switch threadPhase {
            case .awaitingThread(var queued):
                queued.append(inputs)
                threadPhase = .awaitingThread(queued: queued)
            case .active:
                // `turnStart` only enqueues when `threadID()` is nil.
                break
            }
        }
    }

    func registerApproval(id: UUID, requestID: JSONValue, signature: String) {
        withLock {
            pendingApprovals[id] = PendingApproval(
                requestID: requestID,
                signature: signature
            )
        }
    }

    func takeApproval(id: UUID, remember: Bool) -> PendingApproval? {
        withLock {
            guard let approval = pendingApprovals.removeValue(forKey: id) else {
                return nil
            }
            if remember {
                autoApprovalSignatures.insert(approval.signature)
            }
            return approval
        }
    }

    func shouldAutoApprove(signature: String) -> Bool {
        withLock { autoApprovalSignatures.contains(signature) }
    }

    func itemUUID(for itemID: String, random: any RandomSource) -> UUID {
        withLock {
            if let existing = itemIDs[itemID] { return existing }
            let id = random.uuid()
            itemIDs[itemID] = id
            return id
        }
    }

    func markItemStarted(_ itemID: String, at date: Date) {
        withLock { itemStartedAt[itemID] = date }
    }

    func takeItemStartedAt(_ itemID: String) -> Date? {
        withLock { itemStartedAt.removeValue(forKey: itemID) }
    }

    func appendAssistantDelta(_ delta: String, itemID: String) -> String {
        withLock {
            assistantTextByItemID[itemID, default: ""] += delta
            return assistantTextByItemID[itemID] ?? delta
        }
    }

    func clearAssistantText(itemID: String) {
        _ = withLock { assistantTextByItemID.removeValue(forKey: itemID) }
    }

    func selectModel(_ option: AgentModelOption) {
        selectModel(code: option.code, thinkingEffort: option.thinkingEffort)
    }

    func selectModel(code: String, thinkingEffort: String?) {
        withLock {
            selectedModelCodeStorage = code
            selectedThinkingEffortStorage = thinkingEffort
        }
    }

    func selectedModel() -> String? {
        withLock { selectedModelCodeStorage }
    }

    func selectedThinkingEffort() -> String? {
        withLock { selectedThinkingEffortStorage }
    }

    private func withLock<Value>(_ operation: () -> Value) -> Value {
        lock.lock()
        defer { lock.unlock() }
        return operation()
    }
}
