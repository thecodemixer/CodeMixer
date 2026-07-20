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
    /// Live tool-call metadata retained until `tool_call_update` completes.
    private var toolMetaByID: [String: (name: String, inputJSON: String?)] = [:]
    private var agentCapabilities: JSONValue?
    private var availableModesStorage: [ACPSessionMode] = []
    private var currentModeIDStorage: String?
    private var availableModelOptions: [AgentModelOption] = []
    private var currentModelIDStorage: String?

    /// Role of the in-flight `session/load` history buffer (nil when idle).
    private enum ReplayRole: Sendable, Equatable {
        case user
        case agent
        case thinking
    }

    private var replayRole: ReplayRole?
    private var replayMessageID: String?
    private var replayText = ""
    private var replayEventID: UUID?
    /// Live-turn thought accumulator (persisted on prompt finalize).
    private var thoughtText = ""

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
            toolMetaByID.removeAll()
            agentCapabilities = nil
            availableModesStorage = []
            currentModeIDStorage = nil
            availableModelOptions = []
            currentModelIDStorage = nil
            thoughtText = ""
            clearReplayLocked()
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
            toolMetaByID.removeAll()
            phaseStorage = .awaitingSession
            availableModesStorage = []
            currentModeIDStorage = nil
            availableModelOptions = []
            currentModelIDStorage = nil
            thoughtText = ""
            clearReplayLocked()
        }
    }

    /// Switch the live ACP process onto another session id without re-running
    /// initialize/auth. Keeps advertised capabilities from the current process.
    func prepareLoadSession(sessionID: String) {
        withLock {
            guard let existing = context else { return }
            context = Context(
                workspace: existing.workspace,
                permissionMode: existing.permissionMode,
                customAgentID: existing.customAgentID,
                displayName: existing.displayName,
                resumeSessionID: sessionID
            )
            requests.removeAll()
            sessionIDStorage = nil
            queuedPrompts.removeAll()
            pendingApprovals.removeAll()
            itemIDs.removeAll()
            assistantTextByItemID.removeAll()
            thinkingBlockIDs.removeAll()
            toolMetaByID.removeAll()
            phaseStorage = .awaitingSession
            availableModesStorage = []
            currentModeIDStorage = nil
            availableModelOptions = []
            currentModelIDStorage = nil
            thoughtText = ""
            clearReplayLocked()
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

    func setSessionModes(currentModeID: String?, available: [ACPSessionMode]) {
        withLock {
            self.currentModeIDStorage = currentModeID
            self.availableModesStorage = available
        }
    }

    func setCurrentModeID(_ modeID: String) {
        withLock { currentModeIDStorage = modeID }
    }

    func currentModeID() -> String? {
        withLock { currentModeIDStorage }
    }

    func availableModes() -> [ACPSessionMode] {
        withLock { availableModesStorage }
    }

    func availableModeIDs() -> [String] {
        withLock { availableModesStorage.map(\.id) }
    }

    func supportsMode(_ modeID: String) -> Bool {
        withLock { availableModesStorage.contains { $0.id == modeID } }
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

    /// Drop turn-scoped synthetic ids so the next prompt allocates fresh
    /// assistant / thinking identities (avoids SwiftUI row collisions).
    func resetTurnScopedIDs() {
        withLock { thinkingBlockIDs.removeAll() }
    }

    func thinkingBlockID(for key: String, random: any RandomSource) -> UUID {
        withLock {
            if let existing = thinkingBlockIDs[key] { return existing }
            let id = random.uuid()
            thinkingBlockIDs[key] = id
            return id
        }
    }

    func rememberToolStart(id: String, name: String, inputJSON: String?) {
        withLock { toolMetaByID[id] = (name, inputJSON) }
    }

    func takeToolMeta(id: String) -> (name: String, inputJSON: String?)? {
        withLock { toolMetaByID.removeValue(forKey: id) }
    }

    func appendThoughtDelta(_ delta: String) {
        withLock { thoughtText += delta }
    }

    /// Thought text accumulated this turn (for local session-index persistence).
    func takeThoughtText() -> String? {
        withLock {
            let text = thoughtText
            thoughtText = ""
            return text.isEmpty ? nil : text
        }
    }

    /// Close an open live thinking block (first assistant chunk or prompt finalize).
    func takeOpenThinkingBlockID() -> UUID? {
        withLock { thinkingBlockIDs.removeValue(forKey: "thought") }
    }

    /// Append a history chunk during `session/load`. Emits finalized turns when
    /// the role or `messageId` boundary changes.
    func appendHistoryChunk(role: String,
                            messageID: String?,
                            delta: String,
                            random: any RandomSource) -> [AgentEvent] {
        withLock {
            guard !delta.isEmpty else { return [] }
            let nextRole: ReplayRole
            switch role {
            case "user": nextRole = .user
            case "thinking": nextRole = .thinking
            default: nextRole = .agent
            }
            var events: [AgentEvent] = []
            let boundary = replayRole != nil && (
                replayRole != nextRole
                    || (messageID != nil && replayMessageID != nil && messageID != replayMessageID)
            )
            if boundary {
                events.append(contentsOf: flushReplayLocked())
            }
            if replayRole == nil {
                replayRole = nextRole
                replayMessageID = messageID
                replayEventID = random.uuid()
                replayText = ""
            } else if messageID != nil {
                replayMessageID = messageID
            }
            replayText += delta
            return events
        }
    }

    func flushHistoryReplay() -> [AgentEvent] {
        withLock { flushReplayLocked() }
    }

    private func flushReplayLocked() -> [AgentEvent] {
        defer { clearReplayLocked() }
        guard let role = replayRole,
              let id = replayEventID,
              !replayText.isEmpty else { return [] }
        let text = replayText
        switch role {
        case .user:
            return [.userTurn(id: id.uuidString, text: text)]
        case .agent:
            return [.assistantText(
                id: id.uuidString,
                blockID: replayMessageID ?? "history-agent",
                text: text,
                isFinal: true
            )]
        case .thinking:
            // Chunk then complete so EngineViewModel can materialize the text.
            return [
                .thinkingChunk(blockID: id, delta: text),
                .thinkingComplete(blockID: id, duration: .zero),
            ]
        }
    }

    private func clearReplayLocked() {
        replayRole = nil
        replayMessageID = nil
        replayText = ""
        replayEventID = nil
    }

    private func withLock<T>(_ body: () -> T) -> T {
        lock.lock()
        defer { lock.unlock() }
        return body()
    }
}
