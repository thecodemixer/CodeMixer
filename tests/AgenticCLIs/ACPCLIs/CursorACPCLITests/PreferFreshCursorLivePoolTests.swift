import Foundation
import Testing
@testable import ACPCLIs
@testable import AgentCore
import AgentProtocol
import AgentTestSupport

/// Live prefer-fresh pool: New Chat may respawn; session switch must not.
@Suite("preferFreshAgentProcess Cursor live pool", .serialized)
struct PreferFreshCursorLivePoolTests {

    @Test("Cursor preferFresh respawns only on New Chat")
    func cursorPreferFreshNewChatOnly() async throws {
        guard LiveCursorACPHarness.isEnabled() else { return }
        if let reason = LiveCursorACPHarness.prerequisiteFailure() {
            Issue.record("\(reason)")
            return
        }
        guard let configuration = LiveCursorACPHarness.defaultConfiguration() else {
            Issue.record("missing Cursor binary")
            return
        }

        let root = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("prefer-fresh-cursor-\(UUID().uuidString)", isDirectory: true)
        let project = root.appendingPathComponent("cursor-proj", isDirectory: true)
        try FileManager.default.createDirectory(at: project, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        var processEnv = ProcessInfo.processInfo.environment
        processEnv["HOME"] = root.path
        processEnv["CURSOR_BIN"] = configuration.executablePath
        let env = FakeEnvironment(processEnv: processEnv, home: root)
        let fs = SystemFileSystem()
        let engine = AgentEngine(seams: Seams(
            clock: SystemClock(),
            random: SystemRandomSource(),
            environment: env,
            fileSystem: fs
        ))
        await engine.bootstrap()
        await AdapterRegistry.shared.register(CursorACPAdapter(
            environment: env,
            fileSystem: fs
        ))
        defer {
            Task { await engine.shutdown(reason: .naturalExit) }
        }

        let store = WorkspaceProjectsStore(environment: env, fileSystem: fs)
        await store.load()
        _ = try await store.addExistingProject(
            url: project,
            projectType: .cursorCLI,
            preferFreshAgentProcess: true,
            in: root
        )

        let sink = PreferFreshCursorEventSink()
        let sub = await engine.bus.subscribe()
        let collector = Task { await sink.ingest(sub.stream) }
        var responded: Set<PermissionPromptID> = []
        let approver = Task {
            while !Task.isCancelled {
                if let id = await sink.pendingPermissionID(excluding: responded) {
                    responded.insert(id)
                    try? await engine.send(.respondToPermission(id: id, decision: .allow))
                }
                try? await Task.sleep(for: .milliseconds(300))
            }
        }
        defer {
            approver.cancel()
            collector.cancel()
            Task { await engine.bus.unsubscribe(sub.id) }
        }

        try await engine.send(.openProject(path: project.path, resumeSessionID: nil))
        let ready = await pollUntil(timeout: configuration.sessionReadyTimeout) {
            await sink.hasNonEmptySession()
        }
        guard ready, let sessionA = await sink.latestSessionID() else {
            Issue.record("Cursor session never became ready")
            return
        }
        let pidAfterFirst = try await waitForUniqueAgentPID(
            matching: "cursor-agent",
            timeout: .seconds(20)
        )

        try await engine.send(.openProject(path: project.path, resumeSessionID: nil))
        let sawSecond = await pollUntil(timeout: configuration.sessionReadyTimeout) {
            await sink.sessionStartCount() >= 2
        }
        #expect(sawSecond)
        try await Task.sleep(for: .milliseconds(1_000))
        let pidAfterPreferFreshNewChat = try currentAgentPIDs(matching: "cursor-agent")
        #expect(
            pidAfterPreferFreshNewChat.count == 1
                && !pidAfterPreferFreshNewChat.contains(pidAfterFirst),
            "preferFresh New Chat should replace the Cursor ACP process"
        )
        guard let pidAfterNew = pidAfterPreferFreshNewChat.first else { return }

        try await engine.send(.openProject(path: project.path, resumeSessionID: sessionA))
        try await Task.sleep(for: .milliseconds(1_000))
        let pidAfterSwitch = try currentAgentPIDs(matching: "cursor-agent")
        #expect(
            pidAfterSwitch == [pidAfterNew],
            "Session switch must reuse the live Cursor ACP process"
        )
        print(
            "live preferFresh Cursor pool: firstPID=\(pidAfterFirst) afterNewChat=\(pidAfterNew) afterSwitch=\(Array(pidAfterSwitch))"
        )
    }
}

private actor PreferFreshCursorEventSink {
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

    func pendingPermissionID(excluding responded: Set<PermissionPromptID>) -> PermissionPromptID? {
        for event in events.reversed() {
            if case .permissionRequest(let prompt) = event, !responded.contains(prompt.id) {
                return prompt.id
            }
        }
        return nil
    }
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
        try? await Task.sleep(for: .milliseconds(150))
    }
    throw PreferFreshCursorPoolError.timeout(
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

private enum PreferFreshCursorPoolError: Error, CustomStringConvertible {
    case timeout(String)
    var description: String {
        switch self {
        case .timeout(let message): message
        }
    }
}
