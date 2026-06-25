import Foundation
import Observation

/// Text-to-speech for assistant bubbles.
///
/// Splits paragraph-by-paragraph so the user can Skip ahead per section.
/// Markdown is stripped to keep punctuation natural. The actual
/// `AVSpeechSynthesizer` calls live behind `SpeechSynthesis` in
/// `AgentUI/External/`; this file does not import `AVFoundation` directly.
@MainActor
@Observable
public final class TTSService {

    public private(set) var isSpeaking = false
    public private(set) var currentBubbleID: String?

    private let synthesis: SpeechSynthesis

    public init(synthesis: SpeechSynthesis = SpeechSynthesis()) {
        self.synthesis = synthesis
    }

    public func speak(text: String, bubbleID: String) {
        let cleaned = stripMarkdown(text)
        let paragraphs = cleaned
            .split(separator: "\n\n", omittingEmptySubsequences: true)
            .map(String.init)
        for paragraph in paragraphs {
            synthesis.speak(paragraph, rate: 0.5, pitch: 1.0)
        }
        isSpeaking = true
        currentBubbleID = bubbleID
    }

    public func pause() {
        synthesis.pause()
    }

    public func resume() {
        synthesis.resume()
    }

    public func stop() {
        synthesis.stop()
        isSpeaking = false
        currentBubbleID = nil
    }

    public func skipParagraph() {
        synthesis.skipParagraph()
    }

    /// Best-effort markdown stripper for TTS: removes code fences, link
    /// markup, asterisks/underscores, and trims excess whitespace.
    nonisolated static func stripMarkdownForTTS(_ text: String) -> String {
        var out = text
        for pattern in [
            "```[\\s\\S]*?```",
            "`[^`]*`",
            "\\!\\[[^\\]]*\\]\\([^)]*\\)",
        ] {
            if let regex = try? NSRegularExpression(pattern: pattern) {
                let range = NSRange(out.startIndex..., in: out)
                out = regex.stringByReplacingMatches(in: out, range: range, withTemplate: "")
            }
        }
        if let regex = try? NSRegularExpression(pattern: "\\[([^\\]]*)\\]\\([^)]*\\)") {
            let range = NSRange(out.startIndex..., in: out)
            out = regex.stringByReplacingMatches(in: out, range: range, withTemplate: "$1")
        }
        return out
            .replacingOccurrences(of: "**", with: "")
            .replacingOccurrences(of: "*", with: "")
            .replacingOccurrences(of: "_", with: "")
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private func stripMarkdown(_ text: String) -> String {
        Self.stripMarkdownForTTS(text)
    }
}
