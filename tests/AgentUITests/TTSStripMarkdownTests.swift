import Testing
@testable import AgentUI

@Suite("TTSService — markdown stripping")
struct TTSStripMarkdownTests {

    @Test("Code fences are removed")
    func codeFencesAreRemoved() {
        let text = """
        Before
        ```swift
        print("secret")
        ```
        After
        """

        let stripped = TTSService.stripMarkdownForTTS(text)

        #expect(!stripped.contains("print"))
        #expect(stripped.contains("Before"))
        #expect(stripped.contains("After"))
    }

    @Test("Inline code is removed")
    func inlineCodeIsRemoved() {
        #expect(TTSService.stripMarkdownForTTS("Run `swift test` now") == "Run  now")
    }

    @Test("Images are removed")
    func imagesAreRemoved() {
        #expect(TTSService.stripMarkdownForTTS("Look ![alt text](image.png) here") == "Look  here")
    }

    @Test("Links keep their visible label")
    func linksKeepVisibleLabel() {
        #expect(TTSService.stripMarkdownForTTS("Read [the docs](https://example.com)") == "Read the docs")
    }

    @Test("Emphasis markers are stripped and whitespace is trimmed")
    func emphasisMarkersAreStrippedAndWhitespaceTrimmed() {
        let stripped = TTSService.stripMarkdownForTTS("  **Bold** and *italic* plus _under_  ")
        #expect(stripped == "Bold and italic plus under")
    }
}
