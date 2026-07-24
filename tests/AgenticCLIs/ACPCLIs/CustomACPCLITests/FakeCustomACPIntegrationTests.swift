import Foundation
import Testing
@testable import ACPCLIs
@testable import AgentClientProtocol
@testable import AgentCore
import AgentProtocol
import AgentTestSupport

@Suite("AgentEngine + CustomACPAdapter + fake-custom-acp", .serialized)
struct FakeCustomACPIntegrationTests {

    @Test("Custom adapter starts session, exposes migrate/document modes, writes project JSONL")
    func sessionModesAndStore() async throws {
        guard let fakeBin = locateFakeCustomACP() else {
            Issue.record("fake-custom-acp not built — run swift build --product fake-custom-acp")
            return
        }

        let ws = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("custom-acp-ws-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: ws, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: ws) }

        let ref = CustomAgentRef(
            id: "migration-assistant",
            displayName: "Migration Assistant",
            transport: .agentClientProtocol,
            executablePath: fakeBin.path,
            arguments: []
        )
        let env = FakeEnvironment(processEnv: [
            "CODEMIXER_TWIN_SCENARIO": "text",
            "CODEMIXER_CUSTOM_ACP_BIN": fakeBin.path,
            "PATH": "/usr/bin:/bin",
            "SHELL": "/codemixer-test/missing-shell",
        ])
        let fs = SystemFileSystem()
        let factory = CustomACPAdapterFactory()
        guard let adapter = factory.makeAdapter(for: ref) as? CustomACPAdapter else {
            Issue.record("factory failed to build CustomACPAdapter")
            return
        }

        let engine = AgentEngine(seams: Seams(
            clock: SystemClock(),
            random: SystemRandomSource(),
            environment: env,
            fileSystem: fs
        ))
        await engine.bootstrap()

        let sink = CustomEventSink()
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

        // Cached factory instance must surface live modes after session/new.
        let cached = factory.makeAdapter(for: ref) as? CustomACPAdapter
        #expect(cached != nil)
        #expect(ObjectIdentifier(adapter) == ObjectIdentifier(cached!))
        let modes = adapter.availableAgentModes()
        #expect(Set(modes.map(\.id)) == Set(["migrate", "document", "agent"]))
        #expect(modes.first?.id == "migrate")
        #expect(modes.contains { $0.id == "document" && $0.label == "Document" })

        try await engine.send(.runSlashCommand(target: .builtin(name: "/document"), args: []))
        let sawDocument = await pollUntil(timeout: .seconds(5)) {
            await sink.hasStatusPhrase(containing: "document")
        }
        #expect(sawDocument)

        try await engine.send(.runSlashCommand(target: .builtin(name: "/migrate"), args: []))
        let sawMigrate = await pollUntil(timeout: .seconds(5)) {
            await sink.hasStatusPhrase(containing: "migrate")
        }
        #expect(sawMigrate)

        try await engine.send(.sendPrompt(text: "hello custom", attachments: []))
        let sawText = await pollUntil(timeout: .seconds(8)) {
            await sink.hasFinalAssistantText(containing: "Hello from fake-custom-acp")
        }
        #expect(sawText)

        let summaries = await adapter.listResumableSessions(workspace: ws)
        #expect(summaries.contains { $0.title.contains("hello custom") || $0.messageCount > 0 })

        if let sid = summaries.first?.id {
            let url = ACPProjectPaths.transcriptURL(
                projectRoot: ws,
                customAgentID: ref.id,
                sessionID: sid
            )
            #expect(fs.fileExists(at: url))
            let jsonl = String(decoding: try fs.readData(at: url), as: UTF8.self)
            #expect(jsonl.contains("hello custom") || jsonl.contains("user"))
            #expect(fs.fileExists(at: ACPProjectPaths.sessionsIndexURL(
                projectRoot: ws,
                customAgentID: ref.id
            )))
        } else {
            Issue.record("expected resumable session after prompt")
        }

        await engine.shutdown(reason: .naturalExit)
    }

    private func locateFakeCustomACP() -> URL? {
        let cwd = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
        let candidates = [
            cwd.appendingPathComponent(".build/debug/fake-custom-acp"),
            cwd.appendingPathComponent(".build/arm64-apple-macosx/debug/fake-custom-acp"),
        ]
        return candidates.first { FileManager.default.isExecutableFile(atPath: $0.path) }
    }
}

private actor CustomEventSink {
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
            if case .assistantText(_, _, let text, let isFinal) = $0 {
                return isFinal && text.contains(needle)
            }
            return false
        }
    }
}

private func pollUntil(timeout: Duration, _ condition: @escaping @Sendable () async -> Bool) async -> Bool {
    let deadline = ContinuousClock.now + timeout
    while ContinuousClock.now < deadline {
        if await condition() { return true }
        try? await Task.sleep(for: .milliseconds(50))
    }
    return await condition()
}
