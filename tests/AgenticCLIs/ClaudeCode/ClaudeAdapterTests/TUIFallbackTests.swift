import Testing
import Foundation
@testable import ClaudeCode
import AgentCore
import AgentProtocol

@Suite("ClaudeTUIFallback")
struct TUIFallbackTests {

    @Test func parsesEditingLine() async {
        let fallback = ClaudeTUIFallback()
        let snapshot = TerminalSnapshot(plainText: """
        │ Editing file: /workspace/foo.swift                                            │
        """)
        let events = await fallback.ingest(snapshot: snapshot)
        #expect(events.contains { if case .fileTouched = $0 { return true }; return false })
    }

    @Test func parsesAuthURL() async {
        let fallback = ClaudeTUIFallback()
        let snapshot = TerminalSnapshot(plainText: """
        Please visit https://claude.ai/oauth/authorize?session=abc123 to authenticate.
        """)
        let events = await fallback.ingest(snapshot: snapshot)
        #expect(events.contains { if case .authURL = $0 { return true }; return false })
    }

    @Test func parsesStatusPhrase() async {
        let fallback = ClaudeTUIFallback()
        let snapshot = TerminalSnapshot(plainText: "Thinking…")
        let events = await fallback.ingest(snapshot: snapshot)
        #expect(events.contains {
            if case .statusPhraseChanged(.tuiScrape, let phrase) = $0, phrase == "Thinking…" { return true }
            return false
        })
    }

    @Test func deduplicatesAcrossSnapshots() async {
        let fallback = ClaudeTUIFallback()
        let snapshot = TerminalSnapshot(plainText: "│ Editing file: /tmp/x.swift │")
        let first = await fallback.ingest(snapshot: snapshot)
        let second = await fallback.ingest(snapshot: snapshot)
        #expect(first.count == 1)
        #expect(second.isEmpty)
    }

    @Test("seenCount increments on new lines and resets on reset()")
    func seenCountAndReset() async {
        let fallback = ClaudeTUIFallback()
        let s1 = TerminalSnapshot(plainText: "Thinking…")
        let s2 = TerminalSnapshot(plainText: "Running…")
        _ = await fallback.ingest(snapshot: s1)
        _ = await fallback.ingest(snapshot: s2)
        let count = await fallback.seenCount
        #expect(count == 2)
        await fallback.reset()
        let countAfterReset = await fallback.seenCount
        #expect(countAfterReset == 0)
    }

    @Test("parseLine recognises Write/MultiEdit patterns")
    func parseLineAdditionalPatterns() async {
        let fallback = ClaudeTUIFallback()
        let writing = TerminalSnapshot(plainText: "Writing to: /tmp/out.txt")
        let events = await fallback.ingest(snapshot: writing)
        #expect(events.contains { if case .fileTouched = $0 { return true }; return false })
    }

    @Test("workspace trust screen becomes a permission prompt once")
    func workspaceTrustScreenBecomesPermissionPrompt() async {
        let fallback = ClaudeTUIFallback()
        let snapshot = TerminalSnapshot(plainText: """
        Accessing workspace:

        /Users/alice/workspace

        Quick safety check: Is this a project you created or one you trust?
        Claude Code'll be able to read, edit, and execute files here.

        ❯ 1. Yes, I trust this folder
          2. No, exit

        Enter to confirm · Esc to cancel
        """)

        let first = await fallback.ingest(snapshot: snapshot)
        let second = await fallback.ingest(snapshot: snapshot)

        #expect(first.contains {
            if case .permissionRequest(let prompt) = $0 {
                return prompt.toolName == ClaudeTUIFallback.workspaceTrustToolName
                    && prompt.summary == "Trust this workspace?"
                    && prompt.argumentsSummary == "/Users/alice/workspace"
            }
            return false
        })
        #expect(second.isEmpty)
    }

    @Test("workspace trust permission maps allow and deny to TUI choices")
    func workspaceTrustPermissionMapsToTUIChoices() {
        let adapter = ClaudeAdapter()
        let prompt = PermissionPrompt(toolName: ClaudeTUIFallback.workspaceTrustToolName,
                                      summary: "Trust this workspace?",
                                      argumentsSummary: "/Users/alice/workspace",
                                      requestedAt: Date(timeIntervalSince1970: 0))

        guard case .writePTY(let allowBytes) = adapter.encodePermissionResponse(.allow, for: prompt),
              case .writePTY(let allowAlwaysBytes) = adapter.encodePermissionResponse(.allowAlways, for: prompt),
              case .writePTY(let denyBytes) = adapter.encodePermissionResponse(.deny, for: prompt) else {
            Issue.record("workspace trust should respond through PTY")
            return
        }

        #expect(String(decoding: allowBytes, as: UTF8.self) == "1\r")
        #expect(String(decoding: allowAlwaysBytes, as: UTF8.self) == "1\r")
        #expect(String(decoding: denyBytes, as: UTF8.self) == "2\r")
    }
}
