import Foundation

import AgentCore
import AgentProtocol

/// Synchronous session state shared by ACP encoders and the async decoder.
///
/// Safety: every mutable property is accessed only while `lock` is held.
public final class ACPClientState: @unchecked Sendable {
    struct Context: Sendable {
        let workspace: URL
        let permissionMode: PermissionMode
        let customAgentID: String
        let displayName: String
        let resumeSessionID: String?
    }

    enum RequestPurpose: Sendable, Hashable {
        case initialize
        case authenticate
        case sessionNew
        case sessionLoad
        case sessionResume
        case sessionPrompt
        case sessionList
        case sessionSetMode
        case sessionSetModel
        case other(String)
    }

    enum Phase: Sendable, Hashable {
        case idle
        case awaitingInitialize
        case awaitingAuthentication
        case awaitingSession
        case ready
    }

    struct PendingApproval: Sendable, Hashable {
        let requestID: JSONValue
        let optionIDs: [String: String] // kind → optionId
    }

    private let lock = NSLock()
    private var nextID = 1
    private var requests: [JSONValue: RequestPurpose] = [:]
    private var context: Context?
    private var phaseStorage: Phase = .idle
    private var sessionIDStorage: String?
    private var loadSessionSupported = false
    private var resumeSessionSupported = false
    private var listSessionsSupported = false
    private var queuedPrompts: [String] = []
    private var pendingApprovals: [UUID: PendingApproval] = [:]
    private var autoApprovalSignatures: Set<String> = []
    private var itemIDs: [String: UUID] = [:]
    private var assistantTextByItemID: [String: String] = [:]
    private var thinkingBlockIDs: [String: UUID] = [:]
    private var agentCapabilities: JSONValue?
    private var availableModeIDs: [String] = []
    private var currentModeIDStorage: String?
    private var availableModelOptions: [AgentModelOption] = []
    private var currentModelIDStorage: String?

    public init() {}

    func beginSession(context: LaunchContext,
                      customAgentID: String,
                      displayName: String) {
        withLock {
            self.context = Context(
                workspace: context.workspace,
                permissionMode: context.permissionMode,
                customAgentID: customAgentID,
                displayName: displayName,
                resumeSessionID: context.resumeSessionID
            )
            nextID = 1
            requests.removeAll()
            phaseStorage = .awaitingInitialize
            sessionIDStorage = nil
            loadSessionSupported = false
            resumeSessionSupported = false
            listSessionsSupported = false
            queuedPrompts.removeAll()
            pendingApprovals.removeAll()
            autoApprovalSignatures.removeAll()
            itemIDs.removeAll()
            assistantTextByItemID.removeAll()
            thinkingBlockIDs.removeAll()
            agentCapabilities = nil
            availableModeIDs = []
            currentModeIDStorage = nil
            availableModelOptions = []
            currentModelIDStorage = nil
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

    func phase() -> Phase {
        withLock { phaseStorage }
    }

    func setPhase(_ phase: Phase) {
        withLock { phaseStorage = phase }
    }

    func setSessionID(_ id: String) {
        withLock {
            sessionIDStorage = id
            phaseStorage = .ready
        }
    }

    func sessionID() -> String? {
        withLock { sessionIDStorage }
    }

    func prepareNewSession() {
        withLock {
            requests.removeAll()
            sessionIDStorage = nil
            queuedPrompts.removeAll()
            pendingApprovals.removeAll()
            itemIDs.removeAll()
            assistantTextByItemID.removeAll()
            thinkingBlockIDs.removeAll()
            phaseStorage = .awaitingSession
            availableModeIDs = []
            currentModeIDStorage = nil
            availableModelOptions = []
            currentModelIDStorage = nil
        }
    }

    func setAgentCapabilities(_ caps: JSONValue?) {
        withLock {
            agentCapabilities = caps
            loadSessionSupported = caps?["loadSession"]?.boolValue == true
            let sessionCaps = caps?["sessionCapabilities"]?.objectValue
            resumeSessionSupported = sessionCaps?["resume"] != nil
            listSessionsSupported = sessionCaps?["list"] != nil
        }
    }

    func supportsLoadSession() -> Bool {
        withLock { loadSessionSupported }
    }

    func supportsResumeSession() -> Bool {
        withLock { resumeSessionSupported }
    }

    func supportsListSessions() -> Bool {
        withLock { listSessionsSupported }
    }

    func setSessionModes(currentModeID: String?, availableModeIDs: [String]) {
        withLock {
            self.currentModeIDStorage = currentModeID
            self.availableModeIDs = availableModeIDs
        }
    }

    func setCurrentModeID(_ modeID: String) {
        withLock { currentModeIDStorage = modeID }
    }

    func currentModeID() -> String? {
        withLock { currentModeIDStorage }
    }

    func availableModes() -> [String] {
        withLock { availableModeIDs }
    }

    func supportsMode(_ modeID: String) -> Bool {
        withLock { availableModeIDs.contains(modeID) }
    }

    func setSessionModels(currentModelID: String?, available: [AgentModelOption]) {
        withLock {
            currentModelIDStorage = currentModelID
            availableModelOptions = available
        }
    }

    func setCurrentModelID(_ modelID: String) {
        withLock { currentModelIDStorage = modelID }
    }

    func currentModelID() -> String? {
        withLock { currentModelIDStorage }
    }

    func availableModels() -> [AgentModelOption] {
        withLock { availableModelOptions }
    }

    func supportsModel(_ modelID: String) -> Bool {
        withLock { availableModelOptions.contains { $0.id == modelID } }
    }

    func enqueuePrompt(_ text: String) {
        withLock { queuedPrompts.append(text) }
    }

    func takeQueuedPrompts() -> [String] {
        withLock {
            let prompts = queuedPrompts
            queuedPrompts.removeAll()
            return prompts
        }
    }

    func registerApproval(id: UUID, requestID: JSONValue, optionIDs: [String: String]) {
        withLock {
            pendingApprovals[id] = PendingApproval(requestID: requestID, optionIDs: optionIDs)
        }
    }

    func takeApproval(id: UUID) -> PendingApproval? {
        withLock { pendingApprovals.removeValue(forKey: id) }
    }

    func shouldAutoApprove(signature: String) -> Bool {
        withLock { autoApprovalSignatures.contains(signature) }
    }

    func rememberAutoApproval(signature: String) {
        withLock { _ = autoApprovalSignatures.insert(signature) }
    }

    func itemUUID(for itemID: String, random: any RandomSource) -> UUID {
        withLock {
            if let existing = itemIDs[itemID] { return existing }
            let id = random.uuid()
            itemIDs[itemID] = id
            return id
        }
    }

    func appendAssistantDelta(_ delta: String, itemID: String) -> String {
        withLock {
            let next = (assistantTextByItemID[itemID] ?? "") + delta
            assistantTextByItemID[itemID] = next
            return next
        }
    }

    func clearAssistantText(itemID: String) {
        withLock { _ = assistantTextByItemID.removeValue(forKey: itemID) }
    }

    func finalizedAssistantMessage(itemID: String = "agent-message") -> (id: UUID, text: String)? {
        withLock {
            guard let text = assistantTextByItemID[itemID], !text.isEmpty,
                  let id = itemIDs[itemID] else { return nil }
            assistantTextByItemID.removeValue(forKey: itemID)
            itemIDs.removeValue(forKey: itemID)
            return (id, text)
        }
    }

    func thinkingBlockID(for key: String, random: any RandomSource) -> UUID {
        withLock {
            if let existing = thinkingBlockIDs[key] { return existing }
            let id = random.uuid()
            thinkingBlockIDs[key] = id
            return id
        }
    }

    private func withLock<T>(_ body: () -> T) -> T {
        lock.lock()
        defer { lock.unlock() }
        return body()
    }
}
