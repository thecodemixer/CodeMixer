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

    private let lock = NSLock()
    private var nextID = 1
    private var requests: [JSONValue: RequestPurpose] = [:]
    private var context: Context?
    private var threadIDStorage: String?
    private var activeTurnIDStorage: String?
    private var queuedInputs: [[CodexUserInput]] = []
    private var pendingApprovals: [UUID: PendingApproval] = [:]
    private var autoApprovalSignatures: Set<String> = []
    private var itemIDs: [String: UUID] = [:]
    private var itemStartedAt: [String: Date] = [:]
    private var assistantTextByItemID: [String: String] = [:]
    private var selectedModelStorage: String?

    public init() {}

    func beginSession(context: LaunchContext) {
        withLock {
            self.context = Context(
                workspace: context.workspace,
                permissionMode: context.permissionMode
            )
            nextID = 1
            requests.removeAll()
            threadIDStorage = nil
            activeTurnIDStorage = nil
            queuedInputs.removeAll()
            pendingApprovals.removeAll()
            autoApprovalSignatures.removeAll()
            itemIDs.removeAll()
            itemStartedAt.removeAll()
            assistantTextByItemID.removeAll()
            selectedModelStorage = nil
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

    func setThreadID(_ id: String) {
        withLock { threadIDStorage = id }
    }

    func prepareNewThread() {
        withLock {
            requests.removeAll()
            threadIDStorage = nil
            activeTurnIDStorage = nil
            queuedInputs.removeAll()
            pendingApprovals.removeAll()
            autoApprovalSignatures.removeAll()
            itemIDs.removeAll()
            itemStartedAt.removeAll()
            assistantTextByItemID.removeAll()
        }
    }

    func threadID() -> String? {
        withLock { threadIDStorage }
    }

    func beginTurn(_ id: String) {
        withLock { activeTurnIDStorage = id }
    }

    func completeTurn(_ id: String?) {
        withLock {
            guard id == nil || activeTurnIDStorage == id else { return }
            activeTurnIDStorage = nil
        }
    }

    func activeTurn() -> (threadID: String, turnID: String)? {
        withLock {
            guard let threadIDStorage, let activeTurnIDStorage else { return nil }
            return (threadIDStorage, activeTurnIDStorage)
        }
    }

    func enqueue(_ inputs: [CodexUserInput]) {
        withLock { queuedInputs.append(inputs) }
    }

    func takeQueuedInputs() -> [[CodexUserInput]] {
        withLock {
            let inputs = queuedInputs
            queuedInputs.removeAll()
            return inputs
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

    func selectModel(_ id: String) {
        withLock { selectedModelStorage = id }
    }

    func selectedModel() -> String? {
        withLock { selectedModelStorage }
    }

    private func withLock<Value>(_ operation: () -> Value) -> Value {
        lock.lock()
        defer { lock.unlock() }
        return operation()
    }
}
