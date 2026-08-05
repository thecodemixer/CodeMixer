import Testing
@testable import AgentUI

@Suite("Markdown prose renderer")
@MainActor
struct MarkdownProseRenderingTests {
    @Test("unfenced JSON assistant text is treated as code-like in collapsed transcript mode")
    func unfencedJSONIsCodeLike() {
        let snippet = MarkdownProseView.codeLikeSnippet(
            from: #"{"status":"ok","files":[{"path":"orders.ts"}]}"#
        )

        #expect(snippet?.language == "json")
    }

    @Test("ordinary prose is not treated as code-like")
    func ordinaryProseIsNotCodeLike() {
        let snippet = MarkdownProseView.codeLikeSnippet(
            from: "Preserve the public API behavior and verify index assumptions."
        )

        #expect(snippet == nil)
    }
}
