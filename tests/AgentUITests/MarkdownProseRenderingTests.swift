import Testing
@testable import AgentUI

@Suite("Markdown prose renderer")
@MainActor
struct MarkdownProseRenderingTests {
    @Test("reviewer JSON assistant text maps to reviewer comments")
    func reviewerJSONMapsToComments() {
        let text = """
        Reviewer A: {"verdict":"approve","findings":[]}
        Reviewer B: {"verdict":"reject","findings":[{"severity":"high","message":"Missing index"}]}
        """

        let comments = MarkdownProseView.reviewerComments(from: text)

        #expect(comments?.count == 2)
        #expect(comments?.first?.reviewer == "Reviewer A")
        #expect(comments?.first?.verdict == "approve")
        #expect(comments?.last?.findings.first?.message == "Missing index")
    }

    @Test("streamed approve JSON glued to labeled Reviewer A still becomes a card")
    func concatenatedStreamedApproveJSONMapsToCard() {
        // Live ACP often concatenates Reviewer A's streamed verdict object with the
        // later labeled summary on one line; only Reviewer B may land on its own line.
        let approve = #"{"verdict":"approve","findings":[{"severity":"low","message":"Invalid :id model-binding"}]}"#
        let reject = #"{"verdict":"reject","findings":[{"severity":"high","message":"Prefer embedding"}]}"#
        let text = "\(approve)Reviewer A: \(approve)\nReviewer B: \(reject)"

        let content = MarkdownProseView.reviewerContent(from: text)

        #expect(content?.prose == nil)
        #expect(content?.comments.count == 2)
        #expect(content?.comments.contains(where: { $0.reviewer == "Reviewer A" && $0.verdict == "approve" }) == true)
        #expect(content?.comments.contains(where: { $0.reviewer == "Reviewer B" && $0.verdict == "reject" }) == true)
    }

    @Test("bare streamed verdict JSON without a Reviewer prefix still maps to a card")
    func bareVerdictJSONMapsToCard() {
        let text = #"{"verdict":"approve","findings":[{"severity":"low","message":"Minor naming"}]}"#
        let content = MarkdownProseView.reviewerContent(from: text)

        #expect(content?.prose == nil)
        #expect(content?.comments.count == 1)
        #expect(content?.comments.first?.verdict == "approve")
        #expect(content?.comments.first?.findings.first?.message == "Minor naming")
    }

    @Test("reviewer JSON keeps leading assistant prose in the same paragraph")
    func reviewerJSONPreservesLeadingProse() {
        let text = """
        Migration complete. Reviewer verdicts:
        Reviewer A: {"verdict":"approve","findings":[]}
        """

        let content = MarkdownProseView.reviewerContent(from: text)

        #expect(content?.prose == "Migration complete. Reviewer verdicts:")
        #expect(content?.comments.count == 1)
        #expect(content?.comments.first?.verdict == "approve")
    }

    @Test("malformed reviewer JSON does not discard valid reviewer lines")
    func malformedReviewerJSONIsSkipped() {
        let text = """
        Reviewer A: not-json
        Reviewer B: {"verdict":"reject","findings":[]}
        """

        let comments = MarkdownProseView.reviewerComments(from: text)

        #expect(comments?.count == 1)
        #expect(comments?.first?.reviewer == "Reviewer B")
    }

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
