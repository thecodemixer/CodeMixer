import Foundation
import Testing
@testable import AgentUI
@testable import AgentCore
import AgentProtocol
import AgentTestSupport
import ClaudeCode
import Codex
import ACPCLIs

/// Live probe: agent projects with a working-directory override spawn CLIs in
/// the source folder while Codemixer identity stays on the project folder.
///
/// Covers Claude Code, Codex, and Cursor ACP for create + open, default cwd,
/// working-directory edit (cold respawn), and a marker-file prompt check.
///
/// ```bash
/// CODEMIXER_LIVE_WORKING_DIRECTORY=1 \
///   scripts/swift-test.swift --allow-live --filter LiveWorkingDirectoryProbeTests
/// ```
///
/// Optional: `CODEMIXER_LIVE_WORKING_DIRECTORY_AGENTS=claude,codex,cursor`
/// (comma list; default all three).
@Suite("Live working directory — agent project cwd override", .serialized)
struct LiveWorkingDirectoryProbeTests {

    private static let enableVariable = "CODEMIXER_LIVE_WORKING_DIRECTORY"
    private static let agentsVariable = "CODEMIXER_LIVE_WORKING_DIRECTORY_AGENTS"

    @Test("createProject with working-directory override starts Claude/Codex/Cursor in the source folder")
    func createAndOpenUsesWorkingDirectory() async throws {
        guard isEnabled else { return }
        let agents = await selectedAgents()
        guard !agents.isEmpty else {
            Issue.record("no agents selected for live working-directory probe")
            return
        }

        let fixture = try makeFixture(named: "create-open")
        defer { tearDown(fixture) }

        let store = try await makeStore(workspace: fixture.workspace)
        let counter = CountingTransportFactory()

        for agent in agents {
            let source = fixture.sources[agent]!
            let marker = try String(
                contentsOf: source.appendingPathComponent("CWD_MARKER.txt"),
                encoding: .utf8
            ).trimmingCharacters(in: .whitespacesAndNewlines)
            let ref = try await store.createProject(
                name: "proj-\(agent.rawValue)",
                projectType: agent.projectType,
                workingDirectory: source,
                in: fixture.workspace
            )
            #expect(ref.workingDirectoryPath == source.path)
            #expect(ref.path != source.path)

            // One engine per vendor so sessionStarted / readiness never leak.
            let engine = try await makeEngine(counter: counter)
            let sink = EventSink()
            let sub = await engine.bus.subscribe()
            let ingest = Task { await sink.ingest(sub.stream) }
            let approver = Task { await autoApprove(engine: engine, sink: sink) }
            defer {
                approver.cancel()
                ingest.cancel()
                Task {
                    await engine.bus.unsubscribe(sub.id)
                    await engine.shutdown(reason: .naturalExit)
                }
            }

            let spawnBefore = counter.spawnCount
            try await engine.send(.openProject(path: ref.path, resumeSessionID: nil))
            let started = try await waitForSessionStarted(
                sink: sink,
                expectedCWD: source,
                timeout: .seconds(90)
            )
            #expect(counter.spawnCount == spawnBefore + 1)
            #expect(
                samePath(started.cwd, source),
                "\(agent.rawValue) sessionStarted.cwd should be the source folder"
            )
            #expect(
                counter.lastWorkingDirectory.map { samePath($0, source) } == true,
                "\(agent.rawValue) transport launch cwd should be the source folder"
            )

            let prompt = """
                Reply with exactly one line: \(marker)
                Do not add punctuation or explanation.
                """
            do {
                try await engine.send(.sendPrompt(text: prompt, attachments: []))
                let sawMarker = await poll(timeout: .seconds(90)) {
                    await sink.containsFinalAssistantText(matching: marker)
                }
                print("LIVE_CWD \(agent.rawValue) create+open cwd=\(started.cwd.path) spawn=\(counter.spawnCount) marker=\(sawMarker)")
            } catch {
                print("LIVE_CWD \(agent.rawValue) create+open cwd=\(started.cwd.path) spawn=\(counter.spawnCount) prompt-skip=\(error)")
            }
        }
    }

    @Test("without an override, agent cwd equals the project folder")
    func defaultWorkingDirectoryIsProjectFolder() async throws {
        guard isEnabled else { return }
        let agents = await selectedAgents()
        guard !agents.isEmpty else { return }

        let fixture = try makeFixture(named: "default-cwd")
        defer { tearDown(fixture) }

        let store = try await makeStore(workspace: fixture.workspace)
        let counter = CountingTransportFactory()

        for agent in agents {
            let engine = try await makeEngine(counter: counter)
            let sink = EventSink()
            let sub = await engine.bus.subscribe()
            let ingest = Task { await sink.ingest(sub.stream) }
            defer {
                ingest.cancel()
                Task {
                    await engine.bus.unsubscribe(sub.id)
                    await engine.shutdown(reason: .naturalExit)
                }
            }

            let ref = try await store.createProject(
                name: "default-\(agent.rawValue)",
                projectType: agent.projectType,
                in: fixture.workspace
            )
            #expect(ref.workingDirectoryPath == nil)
            let projectURL = URL(fileURLWithPath: ref.path, isDirectory: true)

            try await engine.send(.openProject(path: ref.path, resumeSessionID: nil))
            let started = try await waitForSessionStarted(
                sink: sink,
                expectedCWD: projectURL,
                timeout: .seconds(90)
            )
            #expect(samePath(started.cwd, projectURL))
            #expect(counter.lastWorkingDirectory.map { samePath($0, projectURL) } == true)
            print("LIVE_CWD \(agent.rawValue) default cwd=\(started.cwd.path)")
        }
    }

    @Test("editing working directory cold-starts the next open in the new source folder")
    func editWorkingDirectoryColdStarts() async throws {
        guard isEnabled else { return }
        let agents = await selectedAgents()
        guard !agents.isEmpty else { return }

        let fixture = try makeFixture(named: "edit-cwd")
        defer { tearDown(fixture) }

        let store = try await makeStore(workspace: fixture.workspace)

        for agent in agents {
            let first = fixture.sources[agent]!
            let second = fixture.root.appendingPathComponent("source-edited-\(agent.rawValue)",
                                                             isDirectory: true)
            try FileManager.default.createDirectory(at: second, withIntermediateDirectories: true)
            try "edited-marker-\(agent.rawValue)".write(
                to: second.appendingPathComponent("CWD_MARKER.txt"),
                atomically: true,
                encoding: .utf8
            )

            let counter = CountingTransportFactory()
            let engine = try await makeEngine(counter: counter)
            let sink = EventSink()
            let sub = await engine.bus.subscribe()
            let ingest = Task { await sink.ingest(sub.stream) }
            defer {
                ingest.cancel()
                Task {
                    await engine.bus.unsubscribe(sub.id)
                    await engine.shutdown(reason: .naturalExit)
                }
            }

            let ref = try await store.createProject(
                name: "edit-\(agent.rawValue)",
                projectType: agent.projectType,
                workingDirectory: first,
                in: fixture.workspace
            )

            try await engine.send(.openProject(path: ref.path, resumeSessionID: nil))
            _ = try await waitForSessionStarted(sink: sink, expectedCWD: first, timeout: .seconds(90))
            #expect(counter.spawnCount == 1)
            #expect(counter.lastWorkingDirectory.map { samePath($0, first) } == true)

            _ = try await store.setWorkingDirectory(path: ref.path, to: second, in: fixture.workspace)
            await sink.reset()
            try await engine.send(.openProject(path: ref.path, resumeSessionID: nil))
            let restarted = try await waitForSessionStarted(
                sink: sink,
                expectedCWD: second,
                timeout: .seconds(90)
            )
            #expect(counter.spawnCount == 2, "cwd edit must drop the stale pooled slot")
            #expect(samePath(restarted.cwd, second))
            #expect(counter.lastWorkingDirectory.map { samePath($0, second) } == true)
            print("LIVE_CWD \(agent.rawValue) edit \(first.path) → \(second.path) spawn=\(counter.spawnCount)")
        }
    }

    @Test("addExistingProject keeps cwd as the selected folder until Project Info overrides it")
    func addExistingDefaultsToSelectedFolder() async throws {
        guard isEnabled else { return }
        let agents = await selectedAgents()
        guard !agents.isEmpty else { return }

        let fixture = try makeFixture(named: "add-existing")
        defer { tearDown(fixture) }

        let store = try await makeStore(workspace: fixture.workspace)
        let counter = CountingTransportFactory()

        for agent in agents {
            let existing = fixture.workspace.appendingPathComponent("existing-\(agent.rawValue)",
                                                                    isDirectory: true)
            try FileManager.default.createDirectory(at: existing, withIntermediateDirectories: true)

            let ref = try await store.addExistingProject(
                url: existing,
                projectType: agent.projectType,
                in: fixture.workspace
            )
            #expect(ref.workingDirectoryPath == nil)
            #expect(ref.workingDirectoryURL.path == existing.path)

            let engine = try await makeEngine(counter: counter)
            let sink = EventSink()
            let sub = await engine.bus.subscribe()
            let ingest = Task { await sink.ingest(sub.stream) }
            defer {
                ingest.cancel()
                Task {
                    await engine.bus.unsubscribe(sub.id)
                    await engine.shutdown(reason: .naturalExit)
                }
            }

            try await engine.send(.openProject(path: ref.path, resumeSessionID: nil))
            let started = try await waitForSessionStarted(
                sink: sink,
                expectedCWD: existing,
                timeout: .seconds(90)
            )
            #expect(samePath(started.cwd, existing))
            print("LIVE_CWD \(agent.rawValue) addExisting cwd=\(started.cwd.path)")
        }
    }

    // MARK: - Fixture / gating

    private var isEnabled: Bool {
        ProcessInfo.processInfo.environment[Self.enableVariable] == "1"
    }

    private enum LiveAgent: String, CaseIterable {
        case claude
        case codex
        case cursor

        var projectType: ProjectType {
            switch self {
            case .claude: return .claudeCode
            case .codex: return .codex
            case .cursor: return .cursorCLI
            }
        }
    }

    private func selectedAgents() async -> [LiveAgent] {
        let raw = ProcessInfo.processInfo.environment[Self.agentsVariable]?
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let wanted: [LiveAgent]
        if let raw, !raw.isEmpty {
            wanted = raw.split(separator: ",").compactMap {
                LiveAgent(rawValue: $0.trimmingCharacters(in: .whitespacesAndNewlines).lowercased())
            }
        } else {
            wanted = LiveAgent.allCases
        }
        var available: [LiveAgent] = []
        for agent in wanted {
            if await agentBinaryAvailable(agent) {
                available.append(agent)
            } else {
                print("LIVE_CWD skip \(agent.rawValue) — binary not found")
            }
        }
        return available
    }

    private func agentBinaryAvailable(_ agent: LiveAgent) async -> Bool {
        let env = await ShellEnvironmentResolver(environment: SystemEnvironment()).resolve()
        do {
            switch agent {
            case .claude:
                _ = try await ClaudeAdapter().locateBinary(env: env)
            case .codex:
                _ = try await CodexAdapter().locateBinary(env: env)
            case .cursor:
                _ = try await CursorACPAdapter().locateBinary(env: env)
            }
            return true
        } catch {
            return false
        }
    }

    private struct Fixture {
        let root: URL
        let workspace: URL
        let sources: [LiveAgent: URL]
    }

    private func makeFixture(named: String) throws -> Fixture {
        let root = TestPaths.underTemporary("live-cwd-\(named)-\(UUID().uuidString)")
        let workspace = root.appendingPathComponent("workspace", isDirectory: true)
        try FileManager.default.createDirectory(at: workspace, withIntermediateDirectories: true)

        var sources: [LiveAgent: URL] = [:]
        for agent in LiveAgent.allCases {
            let source = root.appendingPathComponent("source-\(agent.rawValue)", isDirectory: true)
            try FileManager.default.createDirectory(at: source, withIntermediateDirectories: true)
            try "cwd-marker-\(agent.rawValue)-\(named)"
                .write(to: source.appendingPathComponent("CWD_MARKER.txt"),
                       atomically: true,
                       encoding: .utf8)
            sources[agent] = source
        }
        return Fixture(root: root, workspace: workspace, sources: sources)
    }

    private func tearDown(_ fixture: Fixture) {
        try? FileManager.default.removeItem(at: fixture.root)
    }

    // MARK: - Engine helpers

    private func makeStore(workspace: URL) async throws -> WorkspaceProjectsStore {
        // Uses the live app-support catalog so `openProject` (which rebuilds the
        // store from engine seams) sees the same projects. Fixture paths are
        // under the temp root and unique per run.
        let store = WorkspaceProjectsStore(
            environment: SystemEnvironment(),
            fileSystem: SystemFileSystem()
        )
        await store.load()
        try await store.markActiveWorkspace(workspace)
        return store
    }

    private func makeEngine(counter: CountingTransportFactory) async throws -> AgentEngine {
        await AdapterRegistry.shared.register(id: .claudeCode) { ClaudeAdapter() }
        await AdapterRegistry.shared.register(id: .codex) { CodexAdapter() }
        await AdapterRegistry.shared.register(id: .cursorCLI) { CursorACPAdapter() }

        let engine = AgentEngine(seams: .live, transportFactory: counter.make)
        await engine.bootstrap()
        return engine
    }

    private func waitForSessionStarted(
        sink: EventSink,
        expectedCWD: URL,
        timeout: Duration
    ) async throws -> (sessionID: String, cwd: URL) {
        let ok = await poll(timeout: timeout) {
            await sink.latestSessionStarted(matching: expectedCWD) != nil
        }
        guard ok, let started = await sink.latestSessionStarted(matching: expectedCWD) else {
            let events = await sink.snapshot()
            Issue.record("sessionStarted timed out for cwd=\(expectedCWD.path); tail=\(events.suffix(12).map { String(describing: $0).prefix(120) })")
            throw AgentError.unsupportedOperation(detail: "sessionStarted timed out")
        }
        return started
    }

    private func autoApprove(engine: AgentEngine, sink: EventSink) async {
        var responded: Set<PermissionPromptID> = []
        while !Task.isCancelled {
            if let id = await sink.pendingPermissionID(excluding: responded) {
                responded.insert(id)
                try? await engine.send(.respondToPermission(id: id, decision: .allow))
            }
            try? await Task.sleep(for: .milliseconds(400))
        }
    }

    private func poll(timeout: Duration, condition: @escaping () async -> Bool) async -> Bool {
        let deadline = ContinuousClock.now + timeout
        while ContinuousClock.now < deadline {
            if await condition() { return true }
            try? await Task.sleep(for: .milliseconds(250))
        }
        return await condition()
    }

    private func samePath(_ lhs: URL, _ rhs: URL) -> Bool {
        let a = lhs.standardizedFileURL.resolvingSymlinksInPath().path
        let b = rhs.standardizedFileURL.resolvingSymlinksInPath().path
        return a == b
    }
}

// MARK: - Shared helpers

private final class CountingTransportFactory: @unchecked Sendable {
    private let lock = NSLock()
    private(set) var spawnCount = 0
    private(set) var lastWorkingDirectory: URL?

    func make(descriptor: AgentTransportDescriptor,
              launch: AgentTransportLaunchSpec) throws -> any AgentTransport {
        lock.lock()
        spawnCount += 1
        lastWorkingDirectory = launch.workingDirectory
        let n = spawnCount
        let cwd = launch.workingDirectory?.path ?? "(nil)"
        lock.unlock()
        print("LIVE_CWD spawn#\(n) kind=\(descriptor.kind) cwd=\(cwd)")
        return try LiveAgentTransportFactory.make(descriptor: descriptor, launch: launch)
    }
}

private actor EventSink {
    private var events: [AgentEvent] = []

    func ingest(_ stream: AsyncStream<MulticastEventBus.HistoryEntry>) async {
        for await entry in stream {
            events.append(entry.event)
            if events.count > 768 { break }
        }
    }

    func snapshot() -> [AgentEvent] { events }

    func reset() { events.removeAll(keepingCapacity: true) }

    func latestSessionStarted(matching expectedCWD: URL) -> (sessionID: String, cwd: URL)? {
        let expected = expectedCWD.standardizedFileURL.resolvingSymlinksInPath().path
        for event in events.reversed() {
            if case .sessionStarted(let id, _, let cwd) = event, !id.isEmpty {
                let actual = cwd.standardizedFileURL.resolvingSymlinksInPath().path
                if actual == expected {
                    return (id, cwd)
                }
            }
        }
        return nil
    }

    func pendingPermissionID(excluding responded: Set<PermissionPromptID>) -> PermissionPromptID? {
        for event in events.reversed() {
            if case .permissionRequest(let prompt) = event, !responded.contains(prompt.id) {
                return prompt.id
            }
        }
        return nil
    }

    func containsFinalAssistantText(matching substring: String) -> Bool {
        events.contains {
            if case .assistantText(_, _, let text, true) = $0 {
                return text.localizedCaseInsensitiveContains(substring)
            }
            return false
        }
    }
}
