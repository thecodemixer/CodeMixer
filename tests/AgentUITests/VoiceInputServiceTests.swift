import Foundation
import Testing
@testable import AgentUI

@MainActor
@Suite("VoiceInputService")
struct VoiceInputServiceTests {

    @Test("Unauthorized capture leaves service stopped with an error")
    func unauthorizedCaptureDoesNotStart() async {
        let capture = FakeSpeechCapture()
        capture.authorized = false
        let service = VoiceInputService(capture: capture)

        await service.startListening()

        #expect(!service.isListening)
        #expect(service.lastError == "Speech recognition unauthorized")
        #expect(capture.startCount == 0)
    }

    @Test("Partial updates are flushed once when stopped manually")
    func manualStopFlushesPartialTranscript() async {
        let capture = FakeSpeechCapture()
        let service = VoiceInputService(capture: capture)
        var transcripts: [String] = []
        service.onTranscript = { transcripts.append($0) }

        await service.startListening()
        capture.yield(.partial("hello"))
        await drainMainActor()
        service.stopListening()

        #expect(!service.isListening)
        #expect(service.partialTranscript == "")
        #expect(service.latestTranscript == "hello")
        #expect(transcripts == ["hello"])
        #expect(capture.stopCount == 1)
    }

    @Test("Final event publishes transcript once and stops capture")
    func finalEventPublishesOnce() async {
        let capture = FakeSpeechCapture()
        let service = VoiceInputService(capture: capture)
        var transcripts: [String] = []
        service.onTranscript = { transcripts.append($0) }

        await service.startListening()
        capture.yield(.partial("hello"))
        capture.yield(.final("hello world"))
        await drainMainActor()

        #expect(!service.isListening)
        #expect(service.partialTranscript == "")
        #expect(service.latestTranscript == "hello world")
        #expect(transcripts == ["hello world"])
        #expect(capture.stopCount == 1)
    }

    @Test("Audio levels keep the latest thirty samples and reset on stop")
    func audioLevelsRollAndReset() async {
        let capture = FakeSpeechCapture()
        let service = VoiceInputService(capture: capture)

        await service.startListening()
        for sample in 1...35 {
            capture.yield(.audioLevel(Float(sample) / 100))
        }
        await drainMainActor()

        #expect(service.audioLevels.count == 30)
        #expect(service.audioLevels.first == 0.06)
        #expect(service.audioLevels.last == 0.35)

        service.stopListening()

        #expect(service.audioLevels == Array(repeating: Float(0), count: 30))
    }

    @Test("Capture error records message and stops")
    func captureErrorStopsService() async {
        let capture = FakeSpeechCapture()
        let service = VoiceInputService(capture: capture)

        await service.startListening()
        capture.yield(.error("microphone unavailable"))
        await drainMainActor()

        #expect(!service.isListening)
        #expect(service.lastError == "microphone unavailable")
        #expect(capture.stopCount == 1)
    }
}

@MainActor
private final class FakeSpeechCapture: SpeechCapturing {
    var authorized = true
    var startCount = 0
    var stopCount = 0

    private var continuation: AsyncStream<SpeechCapture.Event>.Continuation?

    func requestAuthorization() async -> Bool {
        authorized
    }

    func start() throws -> AsyncStream<SpeechCapture.Event> {
        startCount += 1
        let (stream, continuation) = AsyncStream<SpeechCapture.Event>.makeStream()
        self.continuation = continuation
        return stream
    }

    func stop() {
        stopCount += 1
        continuation?.finish()
        continuation = nil
    }

    func yield(_ event: SpeechCapture.Event) {
        continuation?.yield(event)
    }
}

@MainActor
private func drainMainActor() async {
    for _ in 0..<50 {
        await Task.yield()
    }
}
