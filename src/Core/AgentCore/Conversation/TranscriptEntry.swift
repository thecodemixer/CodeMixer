/// Defines the semantic blocks held by a `SessionTranscript`. These values are
/// independent of both the wire protocol and the JSONL persistence envelope.
import A2UICore
import AgentProtocol
import Foundation

struct TranscriptEntry: Sendable, Codable, Equatable, Identifiable {
    let id: TranscriptEntryID
    let recordedAt: Date
    var block: TranscriptBlock
}

struct TranscriptEntryID: Sendable, Codable, Hashable, RawRepresentable {
    let rawValue: String
}

enum TranscriptBlock: Sendable, Codable, Equatable {
    case user(id: AdapterTurnID, text: String)
    case assistant(id: String, blockID: String, text: String)
    case thinking(blockID: UUID, text: String, durationMS: Int?)
    case tool(ToolTranscript)
    case file(relativePath: String, kind: FileChangeKind)
    case phase(sessionID: String, phase: SessionPhase)
    case clientAction(ClientAction)
    /// One durable, generation-keyed A2UI surface. Folded in place per
    /// `surfaceID` exactly like `.tool`; a `deleteSurface` message removes
    /// the entry outright rather than leaving a tombstone (plan §1/§4 — a
    /// product wanting a static "completed" card instead of deletion should
    /// emit a final `updateComponents` rather than `deleteSurface`).
    case a2uiSurface(A2UISurfaceState)
}

struct ToolTranscript: Sendable, Codable, Equatable {
    let id: ToolCallID
    var name: String
    var input: ToolInput
    var startedAt: Date
    var progress: ToolProgress?
    var success: Bool?
    var output: ToolOutput?
    var durationMS: Int?
}
