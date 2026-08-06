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

@Suite("Markdown block parser")
@MainActor
struct MarkdownBlockParsingTests {
    @Test("headings and bullets in a reasoning trace parse as structure, not prose")
    func headingsAndBullets() {
        let blocks = MarkdownBlock.parse("""
        Context: # fixer migration template

        ## Scope

        FILE: original/InventoryService.cs

        - Preserve externally observable API behavior.
        - Do not invent schema or authorization rules.
        """)

        #expect(blocks.contains { $0 == .heading(level: 2, text: "Scope") })
        guard case .unorderedList(let items)? = blocks.last else {
            Issue.record("expected the trailing bullets to parse as a list")
            return
        }
        #expect(items.map(\.text) == ["Preserve externally observable API behavior.",
                                      "Do not invent schema or authorization rules."])
        // A `#` that is not at the start of a line stays inside the paragraph.
        #expect(blocks.contains { $0 == .paragraph("Context: # fixer migration template") })
    }

    @Test("nested items keep one depth per indent step, whether 2- or 4-space")
    func nestedListDepth() {
        let twoSpace = MarkdownBlock.parse("- top\n  - nested\n    - deeper\n- back")
        let fourSpace = MarkdownBlock.parse("- top\n    - nested\n        - deeper\n- back")
        guard case .unorderedList(let a)? = twoSpace.first,
              case .unorderedList(let b)? = fourSpace.first else {
            Issue.record("expected both indent styles to parse as one list")
            return
        }
        #expect(a.map(\.depth) == [0, 1, 2, 0])
        #expect(b.map(\.depth) == [0, 1, 2, 0])
    }

    @Test("ordered items keep the author's own numbering")
    func orderedListOrdinals() {
        guard case .orderedList(let items)? = MarkdownBlock.parse("3. three\n4. four").first else {
            Issue.record("expected an ordered list")
            return
        }
        #expect(items.map(\.ordinal) == [3, 4])
        #expect(items.map(\.text) == ["three", "four"])
    }

    @Test("a pipe table needs its delimiter row; prose with pipes stays a paragraph")
    func tableRequiresDelimiter() {
        let table = MarkdownBlock.parse("""
        | File | Verdict |
        | --- | :-----: |
        | a.ts | approve |
        | b.ts |
        """)
        #expect(table == [.table(headers: ["File", "Verdict"],
                                 rows: [["a.ts", "approve"], ["b.ts"]])])

        let prose = MarkdownBlock.parse("run `a | b` then `c | d`")
        #expect(prose.allSatisfy { if case .paragraph = $0 { return true } else { return false } })
    }

    @Test("horizontal rules parse as breaks without swallowing bullets")
    func thematicBreaks() {
        #expect(MarkdownBlock.parse("---") == [.thematicBreak])
        #expect(MarkdownBlock.parse("***") == [.thematicBreak])
        #expect(MarkdownBlock.parse("___") == [.thematicBreak])
        guard case .unorderedList(let items)? = MarkdownBlock.parse("- item").first else {
            Issue.record("expected a bullet, not a break")
            return
        }
        #expect(items.map(\.text) == ["item"])
    }

    @Test("spoken text keeps table and list words but drops code and rules")
    func plainTextForSpeech() {
        let spoken = MarkdownProseView.plainText("""
        # Title

        - one
        - two

        ---

        | a | b |
        | - | - |
        | 1 | 2 |

        ```swift
        let x = 1
        ```
        """)

        #expect(spoken.contains("Title"))
        #expect(spoken.contains("one. two"))
        #expect(spoken.contains("a, b"))
        #expect(!spoken.contains("let x = 1"))
    }
}
