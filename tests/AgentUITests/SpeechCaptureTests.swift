import Foundation
import Testing
@testable import AgentUI

/// Wrapper boundary: `AVFoundation.AVAudioEngine` + `Speech.SFSpeechRecognizer`.
/// Real recognition requires microphone authorisation; we only assert the
/// observable lifecycle of the wrapper itself.
@MainActor
@Suite("SpeechCapture")
struct SpeechCaptureTests {

    @Test("Construct + stop() before start() is a no-op")
    func stopBeforeStart() {
        let capture = SpeechCapture()
        capture.stop()
        capture.stop()
    }

    // `requestAuthorization` is excluded from CI because the OS speech
    // authorization dialog can block headless test runners indefinitely.
}
