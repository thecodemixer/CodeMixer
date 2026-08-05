import Foundation

/// Portable identity for the transcript aggregate an A2UI batch/action
/// belongs to. Mirrors `SessionTranscriptKey` (`AgentCore`) without pulling
/// `AgentCore` into `AgentProtocol` — `AgentCore` converts at its boundary.
public struct A2UITranscriptKeyRef: Sendable, Hashable, Codable {
    public let projectRootPath: String
    public let namespace: String
    public let sessionID: String

    public init(projectRootPath: String, namespace: String, sessionID: String) {
        self.projectRootPath = projectRootPath
        self.namespace = namespace
        self.sessionID = sessionID
    }
}

/// One structural or safety-limit rejection for a single batch item.
/// Attribution (`surfaceID`/`path`) is included only when it can be safely
/// recovered from the offending item without trusting unvalidated content.
public struct A2UIValidationIssue: Sendable, Hashable, Codable {
    public let code: String
    public let surfaceID: String?
    public let path: String?
    public let message: String

    public init(code: String, surfaceID: String?, path: String? = nil, message: String) {
        self.code = code
        self.surfaceID = surfaceID
        self.path = path
        self.message = message
    }
}

/// One ordered, atomically-decoded A2UI resource, carried as a typed
/// `AgentEvent`/`AgentEventWire` (never disguised assistant text). A message
/// applies atomically; a failed item leaves prior state unchanged and
/// processing continues with later items (see `A2UISurfaceReducer`).
public struct A2UIServerBatch: Sendable, Hashable, Codable {
    public struct Item: Sendable, Hashable, Codable {
        public let index: Int
        public let message: A2UIServerMessage?
        public let validationError: A2UIValidationIssue?

        public init(index: Int, message: A2UIServerMessage?, validationError: A2UIValidationIssue? = nil) {
            self.index = index
            self.message = message
            self.validationError = validationError
        }
    }

    /// Rawvalue of the `AgentID` that produced this batch (the adapter, not
    /// the migration role) — every surface a batch creates is owned by this
    /// agent for the lifetime of the surface.
    public let agentID: String
    public let transcriptKey: A2UITranscriptKeyRef
    public let resourceURI: String
    public let items: [Item]
    public let recordedAt: Date

    public init(agentID: String,
                transcriptKey: A2UITranscriptKeyRef,
                resourceURI: String,
                items: [Item],
                recordedAt: Date) {
        self.agentID = agentID
        self.transcriptKey = transcriptKey
        self.resourceURI = resourceURI
        self.items = items
        self.recordedAt = recordedAt
    }
}

/// A validated user interaction on a rendered A2UI surface, published by the
/// native renderer up to the engine. This is an *intent*, not a forged
/// action: the renderer supplies only what it directly observed (which
/// component fired, which repeated-list scope it was under, and any
/// not-yet-synced local overlay values needed to resolve dynamic bindings
/// scoped under that component). The engine re-resolves the actual
/// `eventName`/`context` against the canonical durable surface it owns
/// before it is ever encoded onto the wire — see `AgentEngine+A2UI`.
public struct A2UIInteractionIntent: Sendable, Hashable, Codable {
    public let transcriptKey: A2UITranscriptKeyRef
    public let agentID: String
    public let surfaceID: String
    public let generation: Int
    public let sourceComponentID: String
    /// Absolute JSON Pointer prefixes identifying which repeated-list item(s)
    /// (outermost first) the source component was instantiated under, so the
    /// engine can resolve relative bindings the same way the renderer did.
    public let repeatedListScopePaths: [String]
    /// Bounded renderer-local overlay values (e.g. TextField/CheckBox/Slider
    /// edits not yet round-tripped to the server) needed to resolve this
    /// action's context. Never persisted; discarded after evaluation.
    public let localOverlay: A2UILocalOverlay
    public let occurredAt: Date

    public init(transcriptKey: A2UITranscriptKeyRef,
                agentID: String,
                surfaceID: String,
                generation: Int,
                sourceComponentID: String,
                repeatedListScopePaths: [String] = [],
                localOverlay: A2UILocalOverlay = .empty,
                occurredAt: Date) {
        self.transcriptKey = transcriptKey
        self.agentID = agentID
        self.surfaceID = surfaceID
        self.generation = generation
        self.sourceComponentID = sourceComponentID
        self.repeatedListScopePaths = repeatedListScopePaths
        self.localOverlay = localOverlay
        self.occurredAt = occurredAt
    }
}

/// The fully-resolved `client_to_server` action, computed by the engine (not
/// the renderer) from a trusted `A2UIInteractionIntent` plus the canonical
/// surface. This is what actually gets encoded onto the ACP wire.
public struct A2UIActionEnvelope: Sendable, Hashable, Codable {
    public let transcriptKey: A2UITranscriptKeyRef
    public let agentID: String
    public let surfaceID: String
    public let sourceComponentID: String
    public let eventName: String
    public let context: [String: A2UIResolvedValue]
    public let timestamp: Date

    public init(transcriptKey: A2UITranscriptKeyRef,
                agentID: String,
                surfaceID: String,
                sourceComponentID: String,
                eventName: String,
                context: [String: A2UIResolvedValue],
                timestamp: Date) {
        self.transcriptKey = transcriptKey
        self.agentID = agentID
        self.surfaceID = surfaceID
        self.sourceComponentID = sourceComponentID
        self.eventName = eventName
        self.context = context
        self.timestamp = timestamp
    }

    /// Wire-JSON form of `context` for the ACP `client_to_server` encoder.
    /// Lives here (not as a generic `A2UIResolvedValue` accessor) so the
    /// resolved-value type never leaks a `JSONValue` bridge, and is `package`
    /// so the seam is reachable only by in-package wire encoders.
    package var contextWireJSON: [String: JSONValue] {
        context.mapValues(\.jsonValue)
    }
}

/// A client-observed error report the engine forwards as `client_to_server`
/// `error`. Only ever produced by the engine after it can safely recover a
/// version/owner/surface id — see plan §3 rate-limiting note.
public struct A2UIClientErrorEnvelope: Sendable, Hashable, Codable {
    public let transcriptKey: A2UITranscriptKeyRef
    public let agentID: String
    public let surfaceID: String
    public let code: String
    public let path: String?
    public let message: String

    public init(transcriptKey: A2UITranscriptKeyRef,
                agentID: String,
                surfaceID: String,
                code: String,
                path: String? = nil,
                message: String) {
        self.transcriptKey = transcriptKey
        self.agentID = agentID
        self.surfaceID = surfaceID
        self.code = code
        self.path = path
        self.message = message
    }
}
