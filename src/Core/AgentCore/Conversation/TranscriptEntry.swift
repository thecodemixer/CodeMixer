/// Defines the semantic blocks held by a `SessionTranscript`. These values are
/// independent of both the wire protocol and the JSONL persistence envelope.
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
    case user(id: String, text: String)
    case assistant(id: String, blockID: String, text: String)
    case thinking(blockID: UUID, text: String, durationMS: Int?)
    case tool(ToolTranscript)
    case file(relativePath: String, kind: FileChangeKind)
    case phase(sessionID: String, phase: SessionPhase)
    case clientAction(ClientAction)
}

struct ToolTranscript: Sendable, Codable, Equatable {
    let id: String
    var name: String
    var input: ToolInput
    var startedAt: Date
    var progress: ToolProgress?
    var success: Bool?
    var output: ToolOutput?
    var durationMS: Int?
}
