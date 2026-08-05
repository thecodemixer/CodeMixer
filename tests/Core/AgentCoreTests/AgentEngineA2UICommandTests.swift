import Foundation
import Testing
@testable import AgentCore
import AgentProtocol
import AgentTestSupport
import A2UICore

/// Codemixer API coverage for `AgentCommand.submitA2UIInteraction` /
/// `reportA2UIClientError` — the client→server A2UI trust boundary, without
/// a GUI click path.
@Suite("AgentEngine — A2UI command API", .serialized)
struct AgentEngineA2UICommandTests {

    @Test("submitA2UIInteraction re-resolves against the durable surface and writes adapter bytes")
    func submitWritesResolvedAction() async throws {
        let transport = ScriptedTransport()
        let h = try await EngineHarness.make(transport: transport)
        let key = try await seedInteractiveSurface(h: h, surfaceID: "review")

        let intent = A2UIInteractionIntent(
            transcriptKey: key,
            agentID: AgentID.other.rawValue,
            surfaceID: "review",
            generation: 1,
            sourceComponentID: "btn",
            occurredAt: Date(timeIntervalSince1970: 10)
        )
        try await h.engine.send(.submitA2UIInteraction(intent))
        try await Task.sleep(for: .milliseconds(40))

        #expect(h.adapter.recorded.contains {
            if case .a2uiAction(surfaceID: "review", eventName: "migrationReviewDecision") = $0 {
                return true
            }
            return false
        })
        #expect(await transport.writtenTexts().contains {
            $0.contains("a2ui-action:review:migrationReviewDecision")
        })
        await h.shutdown()
    }

    @Test("submitA2UIInteraction with a stale generation records SilentDiagnostics and writes nothing")
    func submitRejectsStaleGeneration() async throws {
        let transport = ScriptedTransport()
        let h = try await EngineHarness.make(transport: transport)
        let key = try await seedInteractiveSurface(h: h, surfaceID: "review")
        await SilentDiagnostics.shared.clear()

        let intent = A2UIInteractionIntent(
            transcriptKey: key,
            agentID: AgentID.other.rawValue,
            surfaceID: "review",
            generation: 0,
            sourceComponentID: "btn",
            occurredAt: Date(timeIntervalSince1970: 10)
        )
        try await h.engine.send(.submitA2UIInteraction(intent))
        try await Task.sleep(for: .milliseconds(40))

        #expect(!h.adapter.recorded.contains {
            if case .a2uiAction = $0 { return true }
            return false
        })
        #expect(await transport.writtenTexts().isEmpty)
        let diag = await SilentDiagnostics.shared.snapshot()
        #expect(diag.contains {
            $0.kind == .a2uiActionRejected && $0.details?.contains("generationMismatch") == true
        })
        await SilentDiagnostics.shared.clear()
        await h.shutdown()
    }

    @Test("reportA2UIClientError forwards the envelope through the adapter encoder")
    func reportClientErrorWrites() async throws {
        let transport = ScriptedTransport()
        let h = try await EngineHarness.make(transport: transport)
        let key = A2UITranscriptKeyRef(
            projectRootPath: h.workspace.path,
            namespace: AgentID.other.rawValue,
            sessionID: "test-session"
        )
        let envelope = A2UIClientErrorEnvelope(
            transcriptKey: key,
            agentID: AgentID.other.rawValue,
            surfaceID: "review",
            code: "VALIDATION_FAILED",
            message: "stale generation"
        )
        try await h.engine.send(.reportA2UIClientError(envelope))
        try await Task.sleep(for: .milliseconds(40))

        #expect(h.adapter.recorded.contains {
            if case .a2uiClientError(surfaceID: "review", code: "VALIDATION_FAILED") = $0 {
                return true
            }
            return false
        })
        #expect(await transport.writtenTexts().contains {
            $0.contains("a2ui-client-error:review:VALIDATION_FAILED")
        })
        await h.shutdown()
    }

    // MARK: - Seeding

    /// Emits one `a2uiBatch` the engine folds into the durable transcript, then
    /// returns the transcript key the command API must use.
    @discardableResult
    private func seedInteractiveSurface(h: EngineHarness,
                                         surfaceID: String) async throws -> A2UITranscriptKeyRef {
        let key = A2UITranscriptKeyRef(
            projectRootPath: h.workspace.path,
            namespace: AgentID.other.rawValue,
            sessionID: "test-session"
        )
        let create = A2UIServerMessage.createSurface(
            surfaceID: surfaceID,
            catalogID: A2UISchemaProfile.testScopedCatalogID,
            theme: nil,
            sendDataModel: false
        )
        let root = try A2UIComponent.decodeKnown(json: .object([
            "id": .string("root"),
            "component": .string("Column"),
            "children": .array([.string("btn")]),
        ]))
        let label = try A2UIComponent.decodeKnown(json: .object([
            "id": .string("btn-label"),
            "component": .string("Text"),
            "text": .string("Accept"),
        ]))
        let button = try A2UIComponent.decodeKnown(json: .object([
            "id": .string("btn"),
            "component": .string("Button"),
            "child": .string("btn-label"),
            "action": .object([
                "event": .object([
                    "name": .string("migrationReviewDecision"),
                    "context": .object([
                        "optionId": .string("accept_a"),
                        "nonce": .string("n1"),
                    ]),
                ]),
            ]),
        ]))
        let update = A2UIServerMessage.updateComponents(
            surfaceID: surfaceID,
            components: [root, label, button]
        )
        #expect(h.adapter.emit(.a2uiBatch(A2UIServerBatch(
            agentID: AgentID.other.rawValue,
            transcriptKey: key,
            resourceURI: "a2ui://test/\(surfaceID)",
            items: [
                .init(index: 0, message: create),
                .init(index: 1, message: update),
            ],
            recordedAt: Date(timeIntervalSince1970: 1)
        ))))
        // Wait until the durable surface is readable through the same path
        // `AgentEngine+A2UI` uses.
        for _ in 0..<40 {
            try await Task.sleep(for: .milliseconds(10))
            let sessionKey = SessionTranscriptKey(
                projectRoot: h.workspace,
                namespace: AgentID.other.rawValue,
                sessionID: "test-session"
            )
            if let surface = try await h.engine.transcriptRepository.a2uiSurface(
                surfaceID: surfaceID,
                for: sessionKey
            ),
               surface.generation == 1,
               surface.components["btn"] != nil {
                return key
            }
        }
        Issue.record("timed out waiting for durable A2UI surface")
        return key
    }
}
