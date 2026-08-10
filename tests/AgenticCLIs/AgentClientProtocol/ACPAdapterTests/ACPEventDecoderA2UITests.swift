import Foundation
@testable import AgentClientProtocol
import AgentCore
import AgentProtocol
import AgentTestSupport
import Testing

@Suite("ACP event decoder — A2UI EmbeddedResource API")
struct ACPEventDecoderA2UITests {

    @Test("MIME-typed A2UI resource in agent_message_chunk becomes a2uiBatch")
    func decodesValidResource() async throws {
        let fixture = ACPDecoderFixture(customAgentID: "custom-acp")
        _ = await fixture.openSession(id: "s1")

        let payload: JSONValue = .array([
            .object([
                "version": .string("v0.9.1"),
                "createSurface": .object([
                    "surfaceId": .string("review"),
                    "catalogId": .string(A2UISchemaProfile.testScopedCatalogID),
                    "sendDataModel": .bool(false),
                ]),
            ]),
        ])
        let text = String(data: try JSONEncoder().encode(payload), encoding: .utf8)!
        let batch = await fixture.decode(.notification(
            method: "session/update",
            params: .object([
                "sessionId": .string("s1"),
                "update": .object([
                    "sessionUpdate": .string("agent_message_chunk"),
                    "content": .object([
                        "type": .string("resource"),
                        "resource": .object([
                            "uri": .string("a2ui://migration/review/x"),
                            "mimeType": .string(A2UISchemaProfile.embeddedResourceMIMEType),
                            "text": .string(text),
                        ]),
                    ]),
                ]),
            ])
        ))

        guard case .a2uiBatch(let a2ui)? = batch.events.first else {
            Issue.record("expected a2uiBatch, got \(batch.events)")
            return
        }
        #expect(a2ui.resourceURI == "a2ui://migration/review/x")
        #expect(a2ui.agentID == "custom-acp")
        #expect(a2ui.items.count == 1)
        #expect(a2ui.items[0].message != nil)
        #expect(a2ui.items[0].validationError == nil)
    }

    @Test("malformed A2UI resource JSON becomes MALFORMED_RESOURCE without dropping the batch")
    func malformedResourceFailsClosed() async {
        let fixture = ACPDecoderFixture()
        _ = await fixture.openSession(id: "s1")

        let batch = await fixture.decode(.notification(
            method: "session/update",
            params: .object([
                "sessionId": .string("s1"),
                "update": .object([
                    "sessionUpdate": .string("tool_call"),
                    "toolCallId": .string("t1"),
                    "title": .string("UI"),
                    "content": .object([
                        "type": .string("resource"),
                        "resource": .object([
                            "uri": .string("a2ui://bad"),
                            "mimeType": .string(A2UISchemaProfile.embeddedResourceMIMEType),
                            "text": .string("{not-json"),
                        ]),
                    ]),
                ]),
            ])
        ))

        guard case .a2uiBatch(let a2ui)? = batch.events.first else {
            Issue.record("expected a2uiBatch carrying validation issue, got \(batch.events)")
            return
        }
        #expect(a2ui.items.count == 1)
        #expect(a2ui.items[0].message == nil)
        #expect(a2ui.items[0].validationError?.code == "MALFORMED_RESOURCE")
    }

    @Test("non-array A2UI root becomes NON_ARRAY_ROOT")
    func nonArrayRootFailsClosed() async {
        let fixture = ACPDecoderFixture()
        _ = await fixture.openSession(id: "s1")

        let batch = await fixture.decode(.notification(
            method: "session/update",
            params: .object([
                "sessionId": .string("s1"),
                "update": .object([
                    "sessionUpdate": .string("agent_message_chunk"),
                    "content": .object([
                        "type": .string("resource"),
                        "resource": .object([
                            "uri": .string("a2ui://obj"),
                            "mimeType": .string(A2UISchemaProfile.embeddedResourceMIMEType),
                            "text": .string(#"{"createSurface":{}}"#),
                        ]),
                    ]),
                ]),
            ])
        ))

        guard case .a2uiBatch(let a2ui)? = batch.events.first else {
            Issue.record("expected a2uiBatch, got \(batch.events)")
            return
        }
        #expect(a2ui.items[0].validationError?.code == "NON_ARRAY_ROOT")
    }

    @Test("wrong MIME type does not activate the A2UI decoder")
    func ignoresWrongMIME() async {
        let fixture = ACPDecoderFixture()
        _ = await fixture.openSession(id: "s1")

        let batch = await fixture.decode(.notification(
            method: "session/update",
            params: .object([
                "sessionId": .string("s1"),
                "update": .object([
                    "sessionUpdate": .string("agent_message_chunk"),
                    "content": .object([
                        "type": .string("resource"),
                        "resource": .object([
                            "uri": .string("a2ui://x"),
                            "mimeType": .string("application/json"),
                            "text": .string("[]"),
                        ]),
                    ]),
                ]),
            ])
        ))

        #expect(!batch.events.contains {
            if case .a2uiBatch = $0 { return true }
            return false
        })
    }
}
