import Foundation
import Testing
@testable import ClaudeCode
@testable import AgentCore
import AgentProtocol
import AgentTestSupport

/// Production-path coverage for the real `ClaudeAdapter` and the fake CLI binary.
@Suite("AgentEngine + ClaudeAdapter + fake-claude", .serialized)
struct FakeClaudeIntegrationTests {

    @Test("spawned fake-claude text turn emits assistantText through production adapter path")
    func spawnedFakeClaudeTextTurn() async throws {
        guard let fakeBin = Self.locateFakeClaude() else {
            Issue.record("fake-claude not built — run swift build --product fake-claude")
            return
        }

        let workspace = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("codemixer-fake-spawn-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: workspace, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: workspace) }

        let home = workspace.appendingPathComponent("home", isDirectory: true)
        try FileManager.default.createDirectory(at: home, withIntermediateDirectories: true)

        let clock = SystemClock()
        var env = FakeEnvironment(
            processEnv: [
                "CLAUDE_BIN": fakeBin.path,
                "CODEMIXER_TWIN_SCENARIO": "text",
                "HOME": home.path,
                "PATH": "/usr/bin:/bin:/usr/sbin:/sbin",
                "SHELL": "/codemixer-test/missing-shell",
            ],
            home: home
        )
        env.processEnv["HOME"] = home.path

        let fs = SystemFileSystem()
        let seams = Seams(clock: clock,
                          random: SystemRandomSource(),
                          environment: env,
                          fileSystem: fs)
        let engine = AgentEngine(seams: seams)
        await engine.bootstrap()

        let adapter = ClaudeAdapter(environment: env, fileSystem: fs, clock: clock)
        let sink = EventSink()
        let sub = await engine.bus.subscribe()
        let collector = Task { await sink.ingest(sub.stream) }
        defer {
            collector.cancel()
            Task { await engine.bus.unsubscribe(sub.id) }
        }

        let sessionID = "sess-spawn-\(UUID().uuidString)"
        try await engine.start(adapter: adapter,
                               workspace: workspace,
                               resumeSessionID: sessionID)

        let sawSession = await pollUntil(timeout: .seconds(5)) {
            await sink.hasSessionStarted()
        }
        #expect(sawSession)
        let hookCommands = ClaudeCodeTwinSettings.loadHookCommands(
            from: ClaudeCodeTwinSettings.settingsURL(for: workspace)
        )
        #expect(hookCommands.contains { $0.eventName == "SessionStart" })
        #expect(hookCommands.contains { $0.eventName == "Stop" })
        guard sawSession else {
            await engine.shutdown(reason: .naturalExit)
            return
        }

        let sendTask = Task {
            try await engine.send(.sendPrompt(text: "hello twin", attachments: []))
        }
        defer { sendTask.cancel() }

        let sawFinalText = await pollUntil(timeout: .seconds(8)) {
            await sink.containsFinalAssistantText()
        }
        if !sawFinalText {
            let summary = transcriptDebugSummary(sessionID: sessionID,
                                                 workspace: workspace,
                                                 claudeDirectory: env.claudeDirectory)
            Issue.record("\(summary)")
        }
        #expect(sawFinalText)
        if sawFinalText {
            try await sendTask.value
        }

        let events = await sink.snapshot()
        await engine.shutdown(reason: .naturalExit)

        #expect(events.contains { if case .sessionStarted = $0 { return true }; return false })
        #expect(events.contains { if case .userTurn(_, let text) = $0 { return text == "hello twin" }; return false })
        #expect(events.contains {
            if case .assistantText(_, _, let text, let isFinal) = $0 {
                return isFinal && text.contains("Hello from the twin.")
            }
            return false
        })
    }

    @Test("adapter transcript path emits assistantText through the engine bus")
    func adapterTranscriptPath() async throws {
        let workspace = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("codemixer-fake-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: workspace, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: workspace) }

        let home = workspace.appendingPathComponent("home", isDirectory: true)
        try FileManager.default.createDirectory(at: home, withIntermediateDirectories: true)

        var env = FakeEnvironment(
            processEnv: [
                "CLAUDE_BIN": "/bin/cat",
                "CODEMIXER_TWIN_SCENARIO": "text",
                "HOME": home.path,
                "PATH": "/usr/bin:/bin",
                "SHELL": "/bin/sh",
            ],
            home: home
        )
        env.processEnv["HOME"] = home.path

        let clock = FakeClock()
        let fs = SystemFileSystem()
        let seams = Seams.fake(clock: clock, environment: env, fileSystem: fs)
        let pty = TestPTY()
        let engine = AgentEngine(seams: seams, transportFactory: { _, _ in pty })
        await engine.bootstrap()

        let adapter = ClaudeAdapter(environment: env, fileSystem: fs, clock: clock)
        let sub = await engine.bus.subscribe()

        let sink = EventSink()
        let collector = Task { await sink.ingest(sub.stream) }
        defer { collector.cancel() }

        let sessionID = "sess-integration"
        let store = ClaudeCodeTwinSessionStore(sessionID: sessionID,
                                               workspace: workspace,
                                               claudeDirectory: env.claudeDirectory)
        try store.append(ClaudeCodeTwinTranscript.assistantTextLine(text: "Hello from fake-claude transcript."))

        try await engine.start(adapter: adapter,
                               workspace: workspace,
                               resumeSessionID: sessionID)
        for _ in 0..<20 {
            clock.advance(by: .milliseconds(100))
            try await Task.sleep(for: .milliseconds(5))
        }

        let events = await sink.snapshot()
        await engine.bus.unsubscribe(sub.id)
        await engine.shutdown(reason: .naturalExit)

        #expect(events.contains { if case .sessionStarted = $0 { return true }; return false })
        #expect(events.contains { if case .assistantText(_, _, let t, let f) = $0 { return f && t.contains("fake-claude transcript") }; return false })
    }

    @Test("auth status --json via fake-claude returns authenticated by default")
    func authStatusJSON() async throws {
        guard let fakeBin = Self.locateFakeClaude() else { return }
        let process = Process()
        process.executableURL = fakeBin
        process.arguments = ["auth", "status", "--json"]
        let pipe = Pipe()
        process.standardOutput = pipe
        try process.run()
        process.waitUntilExit()
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        struct Body: Decodable { let authenticated: Bool? }
        let body = try JSONDecoder().decode(Body.self, from: data)
        #expect(body.authenticated == true)
        #expect(process.terminationStatus == 0)
    }

    private static func locateFakeClaude() -> URL? {
        let cwd = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
        let candidates = [
            cwd.appendingPathComponent(".build/debug/fake-claude"),
            cwd.appendingPathComponent(".build/arm64-apple-macosx/debug/fake-claude"),
        ]
        return candidates.first { FileManager.default.isExecutableFile(atPath: $0.path) }
    }
}

// MARK: - Helpers

private actor EventSink {
    private var events: [AgentEvent] = []

    func ingest(_ stream: AsyncStream<MulticastEventBus.HistoryEntry>) async {
        for await entry in stream {
            events.append(entry.event)
            if events.count > 256 { break }
        }
    }

    func snapshot() -> [AgentEvent] { events }

    func hasSessionStarted() -> Bool {
        events.contains { if case .sessionStarted = $0 { return true }; return false }
    }

    func containsFinalAssistantText() -> Bool {
        events.contains {
            if case .assistantText(_, _, _, let isFinal) = $0 { return isFinal }
            return false
        }
    }
}

private actor TestPTY: AgentTransport {
    nonisolated let outboundBytes: AsyncStream<Data>
    nonisolated let bellEvents: AsyncStream<Void>
    nonisolated var terminalSnapshot: (any TerminalSnapshotting)? { nil }
    private let continuation: AsyncStream<Data>.Continuation
    private var writes: [Data] = []

    init() {
        var continuation: AsyncStream<Data>.Continuation!
        outboundBytes = AsyncStream { continuation = $0 }
        self.continuation = continuation
        var bellCont: AsyncStream<Void>.Continuation!
        bellEvents = AsyncStream { bellCont = $0 }
        bellCont.finish()
    }

    func write(_ data: Data) async throws { writes.append(data) }
    func interrupt() async {}
    func close() async { continuation.finish() }
}

private func pollUntil(timeout: Duration,
                       pollInterval: Duration = .milliseconds(25),
                       condition: @escaping @Sendable () async -> Bool) async -> Bool {
    let deadline = ContinuousClock.now + timeout
    while ContinuousClock.now < deadline {
        if await condition() { return true }
        try? await Task.sleep(for: pollInterval)
    }
    Issue.record("condition not met before timeout")
    return false
}

private func transcriptDebugSummary(sessionID: String,
                                    workspace: URL,
                                    claudeDirectory: URL) -> String {
    let workspaces = ClaudeProjectPaths.workspaceVariants(for: workspace)
    let paths = workspaces.map {
        ClaudeCodeTwinSessionStore(sessionID: sessionID,
                                   workspace: $0,
                                   claudeDirectory: claudeDirectory).transcriptURL
    }
    return paths.map { url in
        let exists = FileManager.default.fileExists(atPath: url.path)
        let size = (try? FileManager.default.attributesOfItem(atPath: url.path)[.size]) ?? "n/a"
        return "\(url.path) exists=\(exists) size=\(size)"
    }.joined(separator: " | ")
}
