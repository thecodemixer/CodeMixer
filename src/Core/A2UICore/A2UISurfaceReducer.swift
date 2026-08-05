import AgentProtocol
import Foundation

/// Pure reducer applying an ordered `A2UIServerBatch` onto a session's live
/// surface set. Every item is validated and applied atomically: a failed
/// item leaves prior state unchanged and processing continues with later
/// items (plan §1 batch semantics). Callers (ACP decode-time validation,
/// transcript replay, `EngineViewModel`'s live projection) all share this
/// one implementation so there is exactly one reduction authority.
public enum A2UISurfaceReducer {
    public struct ItemOutcome: Sendable, Hashable {
        public let index: Int
        public let applied: Bool
        public let issue: A2UIValidationIssue?
    }

    public struct Result: Sendable {
        public let surfaces: [String: A2UISurfaceState]
        /// Highest generation ever assigned per `surfaceId`, retained across
        /// delete so a later recreate still bumps forward (plan §1 "recreate
        /// with the same surfaceId receives a new generation").
        public let retiredGenerations: [String: Int]
        public let outcomes: [ItemOutcome]
    }

    /// Applies every message in `batch` (skipping items that already carried
    /// a decode-time `validationError`) to `surfaces`, returning the updated
    /// surface set and a per-item outcome list in original order.
    /// `retiredGenerations` must be threaded through by the caller across
    /// calls (transcript persistence / `EngineViewModel` both own one copy
    /// per session) so deleted surfaces keep incrementing on recreate.
    public static func apply(_ batch: A2UIServerBatch,
                             to surfaces: [String: A2UISurfaceState],
                             retiredGenerations: [String: Int] = [:],
                             at recordedAt: Date) -> Result {
        var current = surfaces
        var retired = retiredGenerations
        var outcomes: [ItemOutcome] = []
        for item in batch.items {
            if let decodeError = item.validationError {
                outcomes.append(.init(index: item.index, applied: false, issue: decodeError))
                continue
            }
            guard let message = item.message else {
                outcomes.append(.init(index: item.index, applied: false,
                                      issue: .init(code: "MALFORMED", surfaceID: nil,
                                                   message: "Batch item has neither a message nor a validation error.")))
                continue
            }
            if let issue = A2UIValidator.validate(message, existingSurfaces: current) {
                outcomes.append(.init(index: item.index, applied: false, issue: issue))
                continue
            }
            apply(message, agentID: batch.agentID, to: &current, retiredGenerations: &retired, at: recordedAt)
            outcomes.append(.init(index: item.index, applied: true, issue: nil))
        }
        return Result(surfaces: current, retiredGenerations: retired, outcomes: outcomes)
    }

    private static func apply(_ message: A2UIServerMessage,
                              agentID: String,
                              to surfaces: inout [String: A2UISurfaceState],
                              retiredGenerations: inout [String: Int],
                              at recordedAt: Date) {
        switch message {
        case .createSurface(let surfaceID, let catalogID, let theme, let sendDataModel):
            let generation = (retiredGenerations[surfaceID] ?? 0) + 1
            retiredGenerations[surfaceID] = generation
            surfaces[surfaceID] = A2UISurfaceState(surfaceID: surfaceID,
                                                   agentID: agentID,
                                                   catalogID: catalogID,
                                                   theme: theme,
                                                   sendDataModel: sendDataModel,
                                                   generation: generation,
                                                   createdAt: recordedAt)
        case .updateComponents(let surfaceID, let components):
            surfaces[surfaceID]?.replaceComponents(components, at: recordedAt)
        case .updateDataModel(let surfaceID, let path, let value):
            surfaces[surfaceID]?.setDataModel(path: path, value: value, at: recordedAt)
        case .deleteSurface(let surfaceID):
            surfaces.removeValue(forKey: surfaceID)
        }
    }
}
