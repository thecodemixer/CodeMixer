import AgentProtocol
import Foundation

/// Re-resolves a client-observed `A2UIInteractionIntent` against the
/// canonical durable surface the engine owns. This is the trust boundary
/// described in `A2UIServerBatch.swift`.
public enum A2UIActionResolver {
    public enum Failure: Error, Sendable, Equatable {
        case surfaceNotFound
        case generationMismatch
        case componentNotFound
        case notAnEventAction
        case evaluationFailed
    }

    public static func resolve(_ intent: A2UIInteractionIntent,
                               against surface: A2UISurfaceState?,
                               now: Date? = nil) -> Result<(name: String, context: [String: A2UIResolvedValue]), Failure> {
        guard let surface else { return .failure(.surfaceNotFound) }
        guard surface.generation == intent.generation else { return .failure(.generationMismatch) }
        guard let component = surface.components[intent.sourceComponentID] else {
            return .failure(.componentNotFound)
        }
        guard case .button(let props) = component.body,
              case .event(let name, let context) = props.action else {
            return .failure(.notAnEventAction)
        }
        var evaluator = A2UIEvaluator(dataModel: surface.dataModel,
                                      overlay: intent.localOverlay,
                                      scopePaths: intent.repeatedListScopePaths,
                                      now: now)
        guard let resolvedContext = try? evaluator.resolveContext(context) else {
            return .failure(.evaluationFailed)
        }
        return .success((name: name, context: resolvedContext))
    }
}
