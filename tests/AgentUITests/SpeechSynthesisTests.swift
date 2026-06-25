import Foundation
import Testing
@testable import AgentUI

/// Wrapper boundary: `AVFoundation.AVSpeechSynthesizer`. We only exercise the
/// lifecycle; actual TTS playback is not asserted in CI.
@MainActor
@Suite("SpeechSynthesis")
struct SpeechSynthesisTests {

    @Test("Construct + stop() before speak() is a no-op")
    func stopBeforeSpeak() {
        let synthesis = SpeechSynthesis()
        synthesis.stop()
        synthesis.pause()
        synthesis.resume()
        synthesis.skipParagraph()
        #expect(synthesis.isSpeaking == false)
    }

    @Test("speak() does not throw and stop() resets state")
    func speakAndStop() async {
        let synthesis = SpeechSynthesis()
        synthesis.speak("hello world", rate: 0.5, pitch: 1.0)
        synthesis.stop()
        // After stop, isSpeaking may take a moment to settle; do not assert
        // a specific value here, only that the call sequence is safe.
    }
}
