import Foundation
#if canImport(Speech)
import Speech
import AVFoundation
#endif

import AgentCore

@MainActor
public protocol SpeechCapturing: AnyObject {
    func requestAuthorization() async -> Bool
    func start() throws -> AsyncStream<SpeechCapture.Event>
    func stop()
}

/// Single boundary between Codemixer business code and
/// `AVFoundation.AVAudioEngine` + `Speech.SFSpeechRecognizer`.
///
/// `VoiceInputService` consumes the event stream and maps it onto its own
/// observable state. The wrapper has no knowledge of the composer or any
/// UI surface.
@MainActor
public final class SpeechCapture {

    /// Event emitted on the capture stream. The stream finishes after the
    /// final `.final` event or an `.error`.
    public enum Event: Sendable {
        case partial(String)
        case final(String)
        case audioLevel(Float)
        case error(String)
    }

    public enum CaptureError: Error, Sendable, Equatable {
        case unauthorized
        case recognizerUnavailable
        case engineStartFailed(detail: String)
    }

    #if canImport(Speech)
    private let recognizer = SFSpeechRecognizer()
    private let audioEngine = AVAudioEngine()
    private var request: SFSpeechAudioBufferRecognitionRequest?
    private var task: SFSpeechRecognitionTask?
    #endif

    private var continuation: AsyncStream<Event>.Continuation?

    public init() {}

    /// Request `SFSpeechRecognizer.authorization`. Returns `true` when the
    /// user has authorized recognition.
    public func requestAuthorization() async -> Bool {
        #if canImport(Speech)
        await withCheckedContinuation { c in
            SFSpeechRecognizer.requestAuthorization { status in
                c.resume(returning: status == .authorized)
            }
        }
        #else
        false
        #endif
    }

    /// Start audio engine + recognition task. Throws on missing authorization
    /// or audio-engine start failure. The returned stream emits partial /
    /// final transcripts and audio-level samples (~30 Hz).
    public func start() throws -> AsyncStream<Event> {
        #if canImport(Speech)
        guard let recognizer, recognizer.isAvailable else {
            throw CaptureError.recognizerUnavailable
        }

        let req = SFSpeechAudioBufferRecognitionRequest()
        req.shouldReportPartialResults = true
        self.request = req

        let (stream, continuation) = AsyncStream<Event>.makeStream(bufferingPolicy: .bufferingNewest(StreamBufferDefaults.speechEvents))
        self.continuation = continuation

        let input = audioEngine.inputNode
        let format = input.outputFormat(forBus: 0)
        input.installTap(onBus: 0, bufferSize: 1024, format: format) { buffer, _ in
            req.append(buffer)
            let frameCount = Int(buffer.frameLength)
            guard frameCount > 0, let channel = buffer.floatChannelData?[0] else { return }
            let sum = UnsafeBufferPointer(start: channel, count: frameCount)
                .reduce(Float(0)) { $0 + $1 * $1 }
            let rms = Float(sqrt(sum / Float(frameCount)))
            let normalized = min(1.0, rms * 10)
            continuation.yield(.audioLevel(normalized))
        }

        do {
            audioEngine.prepare()
            try audioEngine.start()
        } catch {
            continuation.finish()
            throw CaptureError.engineStartFailed(detail: error.localizedDescription)
        }

        task = recognizer.recognitionTask(with: req) { result, error in
            if let result {
                let text = result.bestTranscription.formattedString
                if result.isFinal {
                    continuation.yield(.final(text))
                    continuation.finish()
                } else {
                    continuation.yield(.partial(text))
                }
            }
            if let error {
                continuation.yield(.error(error.localizedDescription))
                continuation.finish()
            }
        }

        return stream
        #else
        let (stream, continuation) = AsyncStream<Event>.makeStream()
        continuation.finish()
        return stream
        #endif
    }

    /// Stop the audio engine and recognition task. Idempotent. The stream
    /// finishes after any pending partial transcript is flushed as a `.final`.
    public func stop() {
        #if canImport(Speech)
        audioEngine.stop()
        audioEngine.inputNode.removeTap(onBus: 0)
        request?.endAudio()
        task?.cancel()
        task = nil
        request = nil
        #endif
        continuation?.finish()
        continuation = nil
    }
}

extension SpeechCapture: SpeechCapturing {}
