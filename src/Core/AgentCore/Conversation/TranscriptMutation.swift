/// Declares the single mutation alphabet accepted by `SessionTranscript` and
/// persisted by the project-local journal.
import AgentProtocol
import Foundation

enum TranscriptMutation: Sendable, Codable, Equatable {
    case appendUser(id: String, text: String, recordedAt: Date)
    case replaceUser(id: String, text: String, recordedAt: Date)
    case finalizeAssistant(id: String, blockID: String, text: String, recordedAt: Date)
    case appendThinking(blockID: UUID, delta: String, recordedAt: Date)
    case completeThinking(blockID: UUID, durationMS: Int, recordedAt: Date)
    case startTool(id: String, name: String, input: ToolInput, startedAt: Date)
    case updateTool(id: String, progress: ToolProgress, recordedAt: Date)
    case finishTool(id: String, success: Bool, output: ToolOutput, durationMS: Int, recordedAt: Date)
    case touchFile(file: ChangedFile, kind: FileChangeKind, recordedAt: Date)
    case removeChangedFile(ChangedFile, recordedAt: Date)
    case reconcileChangedFiles([ChangedFile], recordedAt: Date)
    case changePhase(sessionID: String, phase: SessionPhase, recordedAt: Date)
    case appendClientAction(ClientAction, recordedAt: Date)
    case truncateAfterUser(id: String, recordedAt: Date)
    /// Folds a whole A2UI batch through `A2UISurfaceReducer` (see
    /// `SessionTranscript.applyA2UIBatch`). Kept as a single mutation instead
    /// of one mutation per surface message so the durable journal stays an
    /// exact record of what the agent actually sent.
    case applyA2UIBatch(A2UIServerBatch, recordedAt: Date)

    var recordedAt: Date {
        switch self {
        case .appendUser(_, _, let date),
             .replaceUser(_, _, let date),
             .finalizeAssistant(_, _, _, let date),
             .appendThinking(_, _, let date),
             .completeThinking(_, _, let date),
             .updateTool(_, _, let date),
             .finishTool(_, _, _, _, let date),
             .touchFile(_, _, let date),
             .removeChangedFile(_, let date),
             .reconcileChangedFiles(_, let date),
             .changePhase(_, _, let date),
             .appendClientAction(_, let date),
             .truncateAfterUser(_, let date),
             .applyA2UIBatch(_, let date):
            return date
        case .startTool(_, _, _, let date):
            return date
        }
    }

    var flushesImmediately: Bool {
        switch self {
        case .appendUser,
             .replaceUser,
             .finalizeAssistant,
             .completeThinking,
             .finishTool,
             .changePhase,
             .appendClientAction,
             .truncateAfterUser,
             .removeChangedFile,
             .reconcileChangedFiles,
             .applyA2UIBatch:
            return true
        case .appendThinking, .startTool, .updateTool, .touchFile:
            return false
        }
    }
}
