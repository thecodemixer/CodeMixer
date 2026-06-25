import Foundation
import Testing
@testable import AgentUI

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
