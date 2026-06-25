import Foundation
#if canImport(AVFoundation)
import AVFoundation
#endif

/// Single boundary between Codemixer business code and
/// `AVFoundation.AVSpeechSynthesizer`.
///
/// `TTSService` keeps markdown stripping, paragraph splitting, and the
/// `currentBubbleID` accounting. This wrapper just speaks utterances.
@MainActor
public final class SpeechSynthesis {

    #if canImport(AVFoundation)
    private let synthesizer = AVSpeechSynthesizer()
    #endif

    public init() {}

    public var isSpeaking: Bool {
        #if canImport(AVFoundation)
        synthesizer.isSpeaking
        #else
        false
        #endif
    }

    /// Enqueue an utterance with the given `rate` (0–1) and `pitch`
    /// (0.5–2.0). Multiple calls queue serially.
    public func speak(_ text: String, rate: Float = 0.5, pitch: Float = 1.0) {
        #if canImport(AVFoundation)
        let utterance = AVSpeechUtterance(string: text)
        utterance.rate = rate
        utterance.pitchMultiplier = pitch
        synthesizer.speak(utterance)
        #endif
    }

    public func pause() {
        #if canImport(AVFoundation)
        synthesizer.pauseSpeaking(at: .immediate)
        #endif
    }

    public func resume() {
        #if canImport(AVFoundation)
        synthesizer.continueSpeaking()
        #endif
    }

    public func stop() {
        #if canImport(AVFoundation)
        synthesizer.stopSpeaking(at: .immediate)
        #endif
    }

    /// Stop the current utterance at the next word boundary so the caller
    /// can advance to the next paragraph without a hard cut.
    public func skipParagraph() {
        #if canImport(AVFoundation)
        synthesizer.stopSpeaking(at: .word)
        #endif
    }
}
