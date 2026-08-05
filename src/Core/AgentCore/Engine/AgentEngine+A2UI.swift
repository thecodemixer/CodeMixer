/// Handles the client-to-server half of the A2UI trust boundary: a validated
/// `A2UIInteractionIntent` (what the renderer directly observed) is re-
/// resolved against the durable canonical surface before anything is ever
/// encoded onto the wire. See `A2UIServerBatch.swift` and `A2UIActionResolver`.
import A2UICore
import AgentProtocol
import Foundation

extension AgentEngine {
    func handleSubmitA2UIInteraction(_ intent: A2UIInteractionIntent, adapter: any AgentAdapter) async throws {
        guard let workspace else {
            throw AgentError.internalInvariant(detail: "submitA2UIInteraction: no workspace bound")
        }
        let key = SessionTranscriptKey(projectRoot: workspace,
                                       namespace: adapter.historyNamespace,
                                       sessionID: intent.transcriptKey.sessionID)
        let surface = try? await transcriptRepository.a2uiSurface(surfaceID: intent.surfaceID, for: key)
        // One clock reading for both context resolution and the envelope, so a
        // `now()` inside the action context agrees with the action's timestamp.
        let now = seams.clock.now()
        switch A2UIActionResolver.resolve(intent, against: surface, now: now) {
        case .success(let resolution):
            let envelope = A2UIActionEnvelope(transcriptKey: intent.transcriptKey,
                                              agentID: intent.agentID,
                                              surfaceID: intent.surfaceID,
                                              sourceComponentID: intent.sourceComponentID,
                                              eventName: resolution.name,
                                              context: resolution.context,
                                              timestamp: now)
            guard let bytes = adapter.encodeA2UIAction(envelope) else {
                await bus.publish(.error(.unsupportedCommand(name: "submitA2UIInteraction")))
                return
            }
            try await writePromptBytes(bytes)
        case .failure(let failure):
            await SilentDiagnostics.shared.record(kind: .a2uiActionRejected,
                                                  owner: "AgentEngine",
                                                  summary: "Rejected A2UI interaction on surface \(intent.surfaceID)",
                                                  details: String(describing: failure))
        }
    }

    func handleReportA2UIClientError(_ envelope: A2UIClientErrorEnvelope, adapter: any AgentAdapter) async throws {
        guard let bytes = adapter.encodeA2UIClientError(envelope) else {
            await bus.publish(.error(.unsupportedCommand(name: "reportA2UIClientError")))
            return
        }
        try await writePromptBytes(bytes)
    }
}
