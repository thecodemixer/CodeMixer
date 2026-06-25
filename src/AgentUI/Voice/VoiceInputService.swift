import Foundation
import Observation

/// Voice dictation surface that drives the composer's mic button.
///
/// Owns observable state (`partialTranscript`, `latestTranscript`,
/// `audioLevels`); the actual `SFSpeechRecognizer` + `AVAudioEngine` plumbing
/// lives behind `SpeechCapture` in `AgentUI/External/`. This file does not
/// import `Speech` or `AVFoundation` directly.
///
/// Marked `@MainActor` because SwiftUI bindings expect main-actor mutation.
@MainActor
@Observable
public final class VoiceInputService {

    public private(set) var isListening = false
    public private(set) var partialTranscript: String = ""
    /// The last finalized transcript. Set just before `partialTranscript` is
    /// cleared, so observers can react to it via `onChange(of: latestTranscript)`.
    public private(set) var latestTranscript: String = ""
    public private(set) var lastError: String?

    /// Rolling audio power levels for the waveform Canvas (30 samples, 0…1).
    /// Updated at ~30 Hz while listening.
    public private(set) var audioLevels: [Float] = Array(repeating: 0, count: 30)

    public var onTranscript: ((String) -> Void)?

    private let capture: any SpeechCapturing
    private var streamTask: Task<Void, Never>?

    public init(capture: any SpeechCapturing = SpeechCapture()) {
        self.capture = capture
    }

    public func requestAuthorization() async -> Bool {
        await capture.requestAuthorization()
    }

    public func startListening() async {
        guard !isListening else { return }
        guard await capture.requestAuthorization() else {
            lastError = "Speech recognition unauthorized"
            return
        }

        let stream: AsyncStream<SpeechCapture.Event>
        do {
            stream = try capture.start()
        } catch let error as SpeechCapture.CaptureError {
            lastError = String(describing: error)
            return
        } catch {
            lastError = error.localizedDescription
            return
        }
        isListening = true

        streamTask = Task { [weak self] in
            for await event in stream {
                guard let self else { return }
                switch event {
                case .partial(let text):
                    self.partialTranscript = text
                case .final(let text):
                    self.latestTranscript = text
                    self.onTranscript?(text)
                    self.finishListening(flushPartial: false)
                case .audioLevel(let level):
                    self.audioLevels.append(level)
                    if self.audioLevels.count > 30 { self.audioLevels.removeFirst() }
                case .error(let message):
                    self.lastError = message
                    self.finishListening(flushPartial: true)
                }
            }
        }
    }

    public func stopListening() {
        finishListening(flushPartial: true)
    }

    private func finishListening(flushPartial: Bool) {
        streamTask?.cancel()
        streamTask = nil
        capture.stop()
        isListening = false
        audioLevels = Array(repeating: 0, count: 30)
        if flushPartial, !partialTranscript.isEmpty {
            latestTranscript = partialTranscript
            onTranscript?(partialTranscript)
        }
        partialTranscript = ""
    }
}
