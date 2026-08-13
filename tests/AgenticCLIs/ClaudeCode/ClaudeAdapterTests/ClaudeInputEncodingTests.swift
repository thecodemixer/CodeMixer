import Testing
import Foundation
@testable import ClaudeCode

@Suite("Claude prompt bytes submit both single-line and multi-line turns")
struct ClaudeInputEncodingTests {

    @Test("A single-line prompt is typed text plus Enter")
    func singleLinePromptIsTypedText() {
        let bytes = ClaudeInputEncoding.userPrompt("Reply with exactly: pong")
        #expect(String(decoding: bytes, as: UTF8.self) == "Reply with exactly: pong\r")
    }

    @Test("A multi-line prompt is wrapped in bracketed paste so Enter still submits")
    func multiLinePromptIsBracketedPaste() {
        let bytes = ClaudeInputEncoding.userPrompt("first line\nsecond line")
        let text = String(decoding: bytes, as: UTF8.self)
        #expect(text == "\u{1B}[200~first line\rsecond line\u{1B}[201~\r")
        #expect(text.hasSuffix("\u{1B}[201~\r"), "the submit Enter must follow the paste end marker")
        #expect(!text.contains("\n"), "interior breaks travel as CR, matching a real terminal paste")
    }

    @Test("An attachment-suffixed prompt still submits as one pasted block")
    func attachmentPromptIsOneBlock() {
        // The engine appends `@<path>` on its own line for attachments, which is
        // the most common way a real turn becomes multi-line.
        let bytes = ClaudeInputEncoding.userPrompt("review this\n@/tmp/file.swift")
        let text = String(decoding: bytes, as: UTF8.self)
        #expect(text.hasPrefix(ClaudeInputEncoding.pasteStart))
        #expect(text.contains("review this\r@/tmp/file.swift"))
        #expect(text.hasSuffix(ClaudeInputEncoding.pasteEnd + "\r"))
    }
}
