import A2UICore
import Foundation
import Testing
@testable import AgentUI
import AgentCore
import AgentProtocol

@Suite("SessionExporter — pure transcript export")
struct SessionExporterTests {

    @Test("Markdown joins user and assistant messages and skips thinking")
    func markdownSkipsThinking() throws {
        let text = try #require(String(data: SessionExporter.markdown(messages()), encoding: .utf8))

        #expect(text.contains("**You:** Hello <world> & friends"))
        #expect(text.contains("Assistant response"))
        #expect(text.contains("Streaming response"))
        #expect(!text.contains("hidden thinking"))
    }

    @Test("JSONL emits one sorted-key object per user and assistant line")
    func jsonlEmitsRoleTextLines() throws {
        let text = try #require(String(data: SessionExporter.jsonl(messages()), encoding: .utf8))
        let lines = text.split(separator: "\n").map(String.init)

        #expect(lines.count == 3)
        #expect(lines[0] == #"{"role":"user","text":"Hello <world> & friends"}"#)
        #expect(lines[1] == #"{"role":"assistant","text":"Assistant response"}"#)
        #expect(lines[2] == #"{"role":"assistant","text":"Streaming response"}"#)
    }

    @Test("HTML escapes user and assistant text")
    func htmlEscapesText() throws {
        let text = try #require(String(data: SessionExporter.html(messages()), encoding: .utf8))

        #expect(text.contains("Hello &lt;world&gt; &amp; friends"))
        #expect(text.contains("<div class=\"assistant\">Assistant response</div>"))
        #expect(!text.contains("Hello <world> & friends"))
    }

    @Test("htmlEscaped replaces ampersand before angle brackets")
    func htmlEscapedOrdering() {
        #expect(SessionExporter.htmlEscaped("<tag attr=\"a&b\">") == "&lt;tag attr=\"a&amp;b\"&gt;")
    }

    @Test("Exports include client-action markers")
    func exportsIncludeClientActions() throws {
        let action = ClientAction(id: UUID(), kind: .mode, title: "Mode", detail: "Think")
        let msgs: [EngineViewModel.Message] = [
            .user(bubbleID: UUID(), text: "hi"),
            .clientAction(action),
            .assistant(bubbleID: UUID(), text: "hello"),
        ]

        let md = try #require(String(data: SessionExporter.markdown(msgs), encoding: .utf8))
        #expect(md.contains("*Mode: Think*"))

        let jsonl = try #require(String(data: SessionExporter.jsonl(msgs), encoding: .utf8))
        #expect(jsonl.contains(#"{"role":"action","text":"Mode: Think"}"#))

        let html = try #require(String(data: SessionExporter.html(msgs), encoding: .utf8))
        #expect(html.contains("<div class=\"action\">Mode: Think</div>"))
    }

    @Test("Domain snapshot messages export the same roles as live UI rows")
    func domainSnapshotExportMatchesUIShape() throws {
        let now = Date(timeIntervalSince1970: 1_700_000_000)
        let messages: [SnapshotService.SnapshotMessage] = [
            .init(role: .user, text: "Hello", timestamp: now),
            .init(role: .action, text: "Mode: Think", timestamp: now),
            .init(role: .assistant, text: "World", timestamp: now),
        ]
        let md = try #require(String(data: SessionExporter.markdown(messages), encoding: .utf8))
        #expect(md.contains("**You:** Hello"))
        #expect(md.contains("*Mode: Think*"))
        #expect(md.contains("World"))
    }

    @Test("A2UI surface rows export the redacted text summary, not raw JSON")
    func exportsA2UISurfaceSummary() throws {
        let batch = A2UIServerBatch(
            agentID: "other",
            transcriptKey: .init(projectRootPath: "/tmp/p", namespace: "other", sessionID: "s1"),
            resourceURI: "a2ui://review",
            items: [
                .init(index: 0, message: .createSurface(
                    surfaceID: "review",
                    catalogID: A2UISchemaProfile.testScopedCatalogID,
                    theme: nil,
                    sendDataModel: false
                )),
                .init(index: 1, message: .updateComponents(
                    surfaceID: "review",
                    components: [
                        try A2UIComponent.decodeKnown(json: .object([
                            "id": .string("root"),
                            "component": .string("Text"),
                            "text": .string("Human review required"),
                        ])),
                    ]
                )),
            ],
            recordedAt: Date(timeIntervalSince1970: 1)
        )
        let surface = try #require(A2UISurfaceReducer.apply(batch, to: [:], at: Date()).surfaces["review"])

        let msgs: [EngineViewModel.Message] = [
            .user(bubbleID: UUID(), text: "migrate"),
            .a2uiSurface(surfaceID: "review"),
        ]
        let md = try #require(String(
            data: SessionExporter.markdown(msgs, a2uiSurfaces: ["review": surface]),
            encoding: .utf8
        ))
        #expect(md.contains("Human review required"))
        #expect(!md.contains("createSurface"))
        #expect(!md.contains("\"component\""))
    }

    private func messages() -> [EngineViewModel.Message] {
        [
            .user(bubbleID: UUID(), text: "Hello <world> & friends"),
            .assistant(bubbleID: UUID(), text: "Assistant response"),
            .assistantStreaming(bubbleID: UUID(), text: "Streaming response"),
            .thinkingChunk(blockID: UUID(), delta: "hidden thinking"),
            .thinkingComplete(blockID: UUID(), text: "hidden thinking", duration: .seconds(1)),
        ]
    }
}
