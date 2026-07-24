import Foundation

import AgentCore
import AgentProtocol

/// Synchronous session state shared by ACP encoders and the async decoder.
///
/// Safety: every mutable property is accessed only while `lock` is held.
/// Methods are grouped by concern into same-file-scoped extensions in this
/// directory: `+Lifecycle` (session begin/prepare/phase/id), `+Capabilities`
/// (advertised agent capabilities, modes, models), `+RequestTracking` (the
/// outgoing-RPC-id → purpose map used to route responses back in
/// `+Session`), `+Replay` (`session/load` history-chunk coalescing),
/// `+Streaming` (live item/thinking/foreign-buffer bookkeeping), and
/// `+Permission` (approvals, auto-approval, parked background permissions).
/// One lock covers all of it — nothing here is composed into separate
/// sub-locks, since several methods (`beginSession`, `prepareNewSession`,
/// `prepareLoadSession`) reset state that spans every concern atomically.
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

    struct ParkedPermission: Sendable {
        let prompt: PermissionPrompt
        let requestID: JSONValue
        let optionIDs: [String: String]
    }

    /// Role of the in-flight `session/load` history buffer (nil when idle).
    enum ReplayRole: Sendable, Equatable {
        case user
        case agent
        case thinking
    }

    /// Non-private: read/written by the concern extensions in this directory.
    let lock = NSLock()
    var nextID = 1
    var requests: [JSONValue: RequestPurpose] = [:]
    var context: Context?
    var phaseStorage: Phase = .idle
    var sessionIDStorage: String?
    var loadSessionSupported = false
    var resumeSessionSupported = false
    var listSessionsSupported = false
    var queuedPrompts: [String] = []
    var pendingApprovals: [UUID: PendingApproval] = [:]
    var autoApprovalSignatures: Set<String> = []
    var itemIDs: [String: UUID] = [:]
    var assistantTextByItemID: [String: String] = [:]
    var thinkingBlockIDs: [String: UUID] = [:]
    /// Live tool-call metadata retained until `tool_call_update` completes.
    var toolMetaByID: [String: (name: String, inputJSON: String?)] = [:]
    var agentCapabilities: JSONValue?
    var availableModesStorage: [ACPSessionMode] = []
    var currentModeIDStorage: String?
    var availableModelOptions: [AgentModelOption] = []
    var currentModelIDStorage: String?
    var replayRole: ReplayRole?
    var replayMessageID: String?
    var replayText = ""
    var replayEventID: UUID?
    /// Live-turn thought accumulator (persisted on prompt finalize).
    var thoughtText = ""
    var parkedPermissionsBySession: [String: [ParkedPermission]] = [:]
    /// Coalesced background-session stream text (sessionId → role + text).
    var foreignBuffers: [String: (role: String, text: String)] = [:]

    public init() {}

    func withLock<T>(_ body: () -> T) -> T {
        lock.lock()
        defer { lock.unlock() }
        return body()
    }
}
