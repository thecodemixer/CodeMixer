import Foundation
import Testing
@testable import ACPCLIs
@testable import AgentClientProtocol
@testable import AgentCore
import AgentProtocol
import AgentTestSupport

/// Engine + CursorACPAdapter + spawned fake-acp covering Cursor mode switches.
@Suite("AgentEngine + CursorACPAdapter + fake-acp", .serialized)
struct FakeCursorACPIntegrationTests {

    @Test("Cursor adapter starts session and switches plan/ask/agent via session/set_mode")
    func modeSwitchRoundTrip() async throws {
        guard let fakeBin = locateFakeACP() else {
            Issue.record("fake-acp not built — run swift build --product fake-acp")
            return
        }

        let ws = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("cursor-acp-ws-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: ws, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: ws) }

        let env = FakeEnvironment(processEnv: [
            "CODEMIXER_TWIN_SCENARIO": "text",
            "CURSOR_BIN": fakeBin.path,
            "PATH": "/usr/bin:/bin",
            "SHELL": "/codemixer-test/missing-shell",
        ])
        let fs = SystemFileSystem()
        let engine = AgentEngine(seams: Seams(
            clock: SystemClock(),
            random: SystemRandomSource(),
            environment: env,
            fileSystem: fs
        ))
        await engine.bootstrap()

        let adapter = CursorACPAdapter(
            environment: env,
            fileSystem: fs,
            clock: SystemClock(),
            random: SystemRandomSource()
        )

        let sink = CursorEventSink()
        let sub = await engine.bus.subscribe()
        let collector = Task { await sink.ingest(sub.stream) }
        defer {
            collector.cancel()
            Task { await engine.bus.unsubscribe(sub.id) }
        }

        try await engine.start(adapter: adapter, workspace: ws)
        let sawSession = await pollUntil(timeout: .seconds(8)) {
            await sink.hasNonEmptySession()
        }
        #expect(sawSession)

        try await engine.send(.setPermissionMode(.plan))
        let sawPlan = await pollUntil(timeout: .seconds(5)) {
            await sink.hasStatusPhrase(containing: "plan")
        }
        #expect(sawPlan)

        try await engine.send(.runSlashCommand(name: "/ask", args: []))
        let sawAsk = await pollUntil(timeout: .seconds(5)) {
            await sink.hasStatusPhrase(containing: "ask")
        }
        #expect(sawAsk)

        try await engine.send(.setPermissionMode(.default))
        let sawAgent = await pollUntil(timeout: .seconds(5)) {
            await sink.hasStatusPhrase(containing: "agent")
        }
        #expect(sawAgent)

        try await engine.send(.sendPrompt(text: "hello", attachments: []))
        let sawText = await pollUntil(timeout: .seconds(8)) {
            await sink.hasFinalAssistantText(containing: "Hello from fake-acp")
        }
        #expect(sawText)

        await engine.shutdown(reason: .naturalExit)
    }

    private func locateFakeACP() -> URL? {
        let cwd = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
        let candidates = [
            cwd.appendingPathComponent(".build/debug/fake-acp"),
            cwd.appendingPathComponent(".build/arm64-apple-macosx/debug/fake-acp"),
        ]
        return candidates.first { FileManager.default.isExecutableFile(atPath: $0.path) }
    }
}

private actor CursorEventSink {
    private var events: [AgentEvent] = []

    func ingest(_ stream: AsyncStream<MulticastEventBus.HistoryEntry>) async {
        for await entry in stream {
            events.append(entry.event)
            if events.count > 512 { break }
        }
    }

    func hasNonEmptySession() -> Bool {
        events.contains {
            if case .sessionStarted(let id, _, _) = $0 { return !id.isEmpty }
            return false
        }
    }

    func hasStatusPhrase(containing needle: String) -> Bool {
        events.contains {
            if case .statusPhraseChanged(_, let phrase) = $0 {
                return phrase.localizedCaseInsensitiveContains(needle)
            }
            return false
        }
    }

    func hasFinalAssistantText(containing needle: String) -> Bool {
        events.contains {
            if case .assistantText(_, _, let text, true) = $0 {
                return text.localizedCaseInsensitiveContains(needle)
            }
            return false
        }
    }
}

private func pollUntil(timeout: Duration, _ condition: @Sendable () async -> Bool) async -> Bool {
    let deadline = ContinuousClock.now + timeout
    while ContinuousClock.now < deadline {
        if await condition() { return true }
        try? await Task.sleep(for: .milliseconds(50))
    }
    return await condition()
}
