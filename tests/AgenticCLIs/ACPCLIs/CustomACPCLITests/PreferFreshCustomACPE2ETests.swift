import Foundation
import Testing
@testable import ACPCLIs
@testable import AgentClientProtocol
@testable import AgentCore
import AgentProtocol
import AgentTestSupport

/// End-to-end pool check: Custom ACP ignores `preferFreshAgentProcess`.
@Suite("preferFreshAgentProcess Custom ACP E2E", .serialized)
struct PreferFreshCustomACPE2ETests {

    @Test("Custom ACP ignores preferFresh across session switch and New Chat")
    func customACPIgnoresPreferFreshAcrossOpens() async throws {
        guard let fakeBin = locateFakeCustomACP() else {
            Issue.record("fake-custom-acp not built — run swift build --product fake-custom-acp")
            return
        }

        let root = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("prefer-fresh-custom-\(UUID().uuidString)", isDirectory: true)
        let project = root.appendingPathComponent("migrate", isDirectory: true)
        try FileManager.default.createDirectory(at: project, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let ref = CustomAgentRef(
            id: "prefer-fresh-custom",
            displayName: "Mixer",
            transport: .agentClientProtocol,
            executablePath: fakeBin.path,
            arguments: []
        )
        let env = FakeEnvironment(
            processEnv: [
                "CODEMIXER_TWIN_SCENARIO": "text",
                "CODEMIXER_CUSTOM_ACP_BIN": fakeBin.path,
                "PATH": "/usr/bin:/bin",
                "SHELL": "/codemixer-test/missing-shell",
                "HOME": root.path,
            ],
            home: root
        )
        let fs = SystemFileSystem()
        let engine = AgentEngine(seams: Seams(
            clock: SystemClock(),
            random: SystemRandomSource(),
            environment: env,
            fileSystem: fs
        ))
        await engine.bootstrap()
        await CustomAgentAdapterFactories.shared.resetForTests()
        await CustomAgentAdapterFactories.shared.register(CustomACPAdapterFactory())
        defer {
            Task {
                await engine.shutdown(reason: .naturalExit)
                await CustomAgentAdapterFactories.shared.resetForTests()
            }
        }

        let store = WorkspaceProjectsStore(environment: env, fileSystem: fs)
        await store.load()
        _ = try await store.addExistingProject(
            url: project,
            projectType: .custom(ref),
            preferFreshAgentProcess: true,
            in: root
        )
        let stored = await store.project(path: project.path)
        #expect(stored?.preferFreshAgentProcess == false)
        #expect(stored?.agentInstanceIdentity == .shared)

        let sink = PreferFreshCustomEventSink()
        let sub = await engine.bus.subscribe()
        let collector = Task { await sink.ingest(sub.stream) }
        defer {
            collector.cancel()
            Task { await engine.bus.unsubscribe(sub.id) }
        }

        try await engine.send(.openProject(path: project.path, resumeSessionID: nil))
        let ready = await pollUntil(timeout: .seconds(10)) {
            await sink.hasNonEmptySession()
        }
        #expect(ready)
        guard let sessionA = await sink.latestSessionID() else {
            Issue.record("missing first session id")
            return
        }
        let pidAfterFirst = try await waitForUniqueAgentPID(
            matching: fakeBin.lastPathComponent,
            timeout: .seconds(5)
        )

        try await engine.send(.openProject(path: project.path, resumeSessionID: sessionA))
        try await Task.sleep(for: .milliseconds(400))
        let pidAfterResume = try currentAgentPIDs(matching: fakeBin.lastPathComponent)
        #expect(pidAfterResume == [pidAfterFirst])

        try await engine.send(.openProject(path: project.path, resumeSessionID: nil))
        let sawNewChatSession = await pollUntil(timeout: .seconds(8)) {
            await sink.sessionStartCount() >= 2
        }
        #expect(sawNewChatSession)
        try await Task.sleep(for: .milliseconds(400))
        let pidAfterNewChat = try currentAgentPIDs(matching: fakeBin.lastPathComponent)
        #expect(
            pidAfterNewChat == [pidAfterFirst],
            "Custom ACP New Chat must reuse the live process even when preferFresh was requested"
        )
    }
}

private actor PreferFreshCustomEventSink {
    private var events: [AgentEvent] = []

    func ingest(_ stream: AsyncStream<MulticastEventBus.HistoryEntry>) async {
        for await entry in stream {
            events.append(entry.event)
            if events.count > 4_096 { events.removeFirst(events.count - 4_096) }
        }
    }

    func hasNonEmptySession() -> Bool {
        events.contains {
            if case .sessionStarted(let id, _, _) = $0 { return !id.isEmpty }
            return false
        }
    }

    func latestSessionID() -> String? {
        for event in events.reversed() {
            if case .sessionStarted(let id, _, _) = event, !id.isEmpty { return id }
        }
        return nil
    }

    func sessionStartCount() -> Int {
        events.reduce(0) { count, event in
            if case .sessionStarted(let id, _, _) = event, !id.isEmpty { return count + 1 }
            return count
        }
    }
}

private func locateFakeCustomACP() -> URL? {
    let cwd = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
    let candidates = [
        cwd.appendingPathComponent(".build/debug/fake-custom-acp"),
        cwd.appendingPathComponent(".build/arm64-apple-macosx/debug/fake-custom-acp"),
    ]
    return candidates.first { FileManager.default.isExecutableFile(atPath: $0.path) }
}

private func currentAgentPIDs(matching needle: String) throws -> Set<Int32> {
    let process = Process()
    process.executableURL = URL(fileURLWithPath: "/usr/bin/pgrep")
    process.arguments = ["-f", needle]
    let pipe = Pipe()
    process.standardOutput = pipe
    process.standardError = Pipe()
    try process.run()
    process.waitUntilExit()
    let data = pipe.fileHandleForReading.readDataToEndOfFile()
    let text = String(decoding: data, as: UTF8.self)
    let pids = text.split(whereSeparator: \.isNewline).compactMap { Int32($0) }
    return Set(pids)
}

private func waitForUniqueAgentPID(matching needle: String,
                                   timeout: Duration) async throws -> Int32 {
    let deadline = ContinuousClock.now + timeout
    var last: Set<Int32> = []
    while ContinuousClock.now < deadline {
        last = try currentAgentPIDs(matching: needle)
        if last.count == 1, let pid = last.first { return pid }
        try? await Task.sleep(for: .milliseconds(100))
    }
    throw PreferFreshCustomPoolError.timeout(
        "expected one \(needle) pid, saw \(Array(last).sorted())"
    )
}

private func pollUntil(timeout: Duration,
                       _ condition: @escaping @Sendable () async -> Bool) async -> Bool {
    let deadline = ContinuousClock.now + timeout
    while ContinuousClock.now < deadline {
        if await condition() { return true }
        try? await Task.sleep(for: .milliseconds(50))
    }
    return await condition()
}

private enum PreferFreshCustomPoolError: Error, CustomStringConvertible {
    case timeout(String)
    var description: String {
        switch self {
        case .timeout(let message): message
        }
    }
}
