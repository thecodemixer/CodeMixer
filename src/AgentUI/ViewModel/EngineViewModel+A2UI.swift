/// Client-to-server half of the A2UI trust boundary from the UI side: builds
/// an `A2UIInteractionIntent` describing what the renderer directly observed
/// and hands it to the engine, which re-resolves it against the canonical
/// surface before anything reaches the wire (see `AgentEngine+A2UI`).
import A2UICore
import AgentProtocol
import Foundation

public extension EngineViewModel {
    /// Called by `A2UISurfaceView.onInteract` when a `Button` with a
    /// server-bound `event` action fires.
    func submitA2UIInteraction(surfaceID: String,
                               sourceComponentID: String,
                               repeatedListScopePaths: [String],
                               localOverlay: A2UILocalOverlay) {
        guard let surface = a2uiSurfaces[surfaceID] else { return }
        let intent = A2UIInteractionIntent(transcriptKey: .init(projectRootPath: workspace?.path ?? "",
                                                                namespace: "",
                                                                sessionID: sessionID ?? ""),
                                           agentID: surface.agentID,
                                           surfaceID: surfaceID,
                                           generation: surface.generation,
                                           sourceComponentID: sourceComponentID,
                                           repeatedListScopePaths: repeatedListScopePaths,
                                           localOverlay: localOverlay,
                                           occurredAt: clock.now())
        Task { try? await engine.send(.submitA2UIInteraction(intent)) }
    }
}
