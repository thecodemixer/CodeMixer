import Foundation
import Testing
@testable import AgentUI
@testable import AgentCore
import AgentProtocol
import ClaudeCode
import Codex
import ACPCLIs

/// Live probe of runtime activation: background projects stay parked; session
/// switches, project returns, and New Chat activate/reuse the live process
/// without respawn. Cold spawn only when the project has no pool slot yet.
///
/// ```bash
/// CODEMIXER_LIVE_RUNTIME_POOL=1 \
/// CODEMIXER_LIVE_CLAUDE_PROJECT_A=/path/to/claude-a \
/// CODEMIXER_LIVE_CLAUDE_PROJECT_B=/path/to/claude-b \
/// CODEMIXER_LIVE_CODEX_PROJECT=/path/to/codex-project \
/// CODEMIXER_LIVE_CURSOR_PROJECT=/path/to/cursor-project \
///   swift test --no-parallel --filter LiveRuntimePoolProbeTests
/// ```
@Suite("Live runtime activation — project and session switches", .serialized)
struct LiveRuntimePoolProbeTests {

    private static let enableVariable = "CODEMIXER_LIVE_RUNTIME_POOL"
    private static let claudeProjectAKey = "CODEMIXER_LIVE_CLAUDE_PROJECT_A"
    private static let claudeProjectBKey = "CODEMIXER_LIVE_CLAUDE_PROJECT_B"
    private static let codexProjectKey = "CODEMIXER_LIVE_CODEX_PROJECT"
    private static let cursorProjectKey = "CODEMIXER_LIVE_CURSOR_PROJECT"

    @Test("Claude cross-project round trip parks and reactivates without respawn")
    func claudeCrossProjectActivation() async throws {
        guard isEnabled else { return }
        guard let paths = requiredProjectPaths() else { return }
        let counter = CountingTransportFactory()
        let engine = try await makeEngine(counter: counter)
        defer { Task { await engine.shutdown(reason: .naturalExit) } }

        try await engine.send(.openProject(path: paths.claudeA, resumeSessionID: nil))
        try await waitUntil(timeout: .seconds(90)) {
            await engine.liveProjectPaths().contains(standardized(paths.claudeA))
                && counter.spawnCount == 1
        }
        #expect(counter.spawnCount == 1)
        print("LIVE_POOL claude A open spawn=\(counter.spawnCount) paths=\(await engine.liveProjectPaths())")

        try await engine.send(.openProject(path: paths.claudeB, resumeSessionID: nil))
        try await waitUntil(timeout: .seconds(90)) {
            let livePaths = await engine.liveProjectPaths()
            return livePaths.contains(standardized(paths.claudeA))
                && livePaths.contains(standardized(paths.claudeB))
                && counter.spawnCount == 2
        }
        #expect(counter.spawnCount == 2)
        print("LIVE_POOL claude B open spawn=\(counter.spawnCount) paths=\(await engine.liveProjectPaths())")

        try await engine.send(.openProject(path: paths.claudeA, resumeSessionID: nil))
        try await waitUntil(timeout: .seconds(60)) {
            await engine.liveProjectPaths().count == 2
        }
        #expect(counter.spawnCount == 2, "returning to A must activate the parked Claude PTY")
        let livePaths = await engine.liveProjectPaths()
        #expect(livePaths.contains(standardized(paths.claudeA)))
        #expect(livePaths.contains(standardized(paths.claudeB)))
        print("LIVE_POOL claude A warm activate spawn=\(counter.spawnCount) paths=\(livePaths)")
    }

    @Test("Claude new-chat and session switch reuse the live PTY")
    func claudeSessionActivation() async throws {
        guard isEnabled else { return }
        guard let paths = requiredProjectPaths() else { return }
        let counter = CountingTransportFactory()
        let engine = try await makeEngine(counter: counter)
        defer { Task { await engine.shutdown(reason: .naturalExit) } }

        try await engine.send(.openProject(path: paths.claudeA, resumeSessionID: nil))
        try await waitUntil(timeout: .seconds(90)) { counter.spawnCount == 1 }
        #expect(await engine.liveProjectPaths().count == 1)
        print("LIVE_POOL claude session#1 spawn=\(counter.spawnCount)")

        try await engine.send(.openProject(path: paths.claudeA, resumeSessionID: nil))
        try await Task.sleep(for: .seconds(2))
        #expect(counter.spawnCount == 1, "Claude New Chat must reuse the live project PTY")
        #expect(await engine.liveProjectPaths().count == 1)
        print("LIVE_POOL claude new-chat warm spawn=\(counter.spawnCount)")

        let other = ClaudeSessionCatalogImporter.summaries(
            workspace: URL(fileURLWithPath: paths.claudeA),
            claudeDirectory: Seams.live.environment.claudeDirectory,
            fileSystem: Seams.live.fileSystem
        ).first
        if let other {
            try await engine.send(.openProject(path: paths.claudeA, resumeSessionID: other.id))
            try await Task.sleep(for: .seconds(4))
            #expect(counter.spawnCount == 1, "Claude session switch must warm-resume on the live PTY")
            #expect(await engine.liveProjectPaths().count == 1)
            print("LIVE_POOL claude session switch → \(other.id) spawn=\(counter.spawnCount)")
        } else {
            print("LIVE_POOL claude no second on-disk session; skip resume-id activation check")
        }
    }

    @Test("Codex cross-project return and new chat reuse the live App Server")
    func codexCrossProjectAndNewChatActivation() async throws {
        guard isEnabled else { return }
        guard let paths = requiredProjectPaths() else { return }
        let counter = CountingTransportFactory()
        let engine = try await makeEngine(counter: counter)
        defer { Task { await engine.shutdown(reason: .naturalExit) } }

        try await engine.send(.openProject(path: paths.codex, resumeSessionID: nil))
        try await waitUntil(timeout: .seconds(90)) {
            await engine.liveProjectPaths().contains(standardized(paths.codex))
                && counter.spawnCount == 1
        }
        print("LIVE_POOL codex open spawn=\(counter.spawnCount)")

        try await engine.send(.openProject(path: paths.claudeA, resumeSessionID: nil))
        try await waitUntil(timeout: .seconds(90)) { counter.spawnCount == 2 }
        #expect(await engine.liveProjectPaths().count == 2)
        print("LIVE_POOL codex→claude spawn=\(counter.spawnCount) paths=\(await engine.liveProjectPaths())")

        try await engine.send(.openProject(path: paths.codex, resumeSessionID: nil))
        try await waitUntil(timeout: .seconds(60)) {
            await engine.liveProjectPaths().contains(standardized(paths.codex))
        }
        #expect(counter.spawnCount == 2, "returning to Codex must activate the parked App Server")
        print("LIVE_POOL codex warm activate spawn=\(counter.spawnCount)")

        try await engine.send(.openProject(path: paths.codex, resumeSessionID: nil))
        try await Task.sleep(for: .seconds(3))
        #expect(counter.spawnCount == 2, "Codex new chat must reuse the live App Server")
        #expect(await engine.liveProjectPaths().count == 2)
        print("LIVE_POOL codex warm new-chat spawn=\(counter.spawnCount) paths=\(await engine.liveProjectPaths())")
    }

    @Test("Cursor ACP new chat reuses the live process via session/new")
    func cursorNewChatActivation() async throws {
        guard isEnabled else { return }
        guard let paths = requiredProjectPaths() else { return }
        let counter = CountingTransportFactory()
        let engine = try await makeEngine(counter: counter)
        defer { Task { await engine.shutdown(reason: .naturalExit) } }

        try await engine.send(.openProject(path: paths.cursor, resumeSessionID: nil))
        try await waitUntil(timeout: .seconds(90)) { counter.spawnCount == 1 }
        print("LIVE_POOL cursor open spawn=\(counter.spawnCount)")

        try await engine.send(.openProject(path: paths.cursor, resumeSessionID: nil))
        try await Task.sleep(for: .seconds(4))
        #expect(counter.spawnCount == 1, "Cursor new chat must reuse the live ACP process")
        #expect(await engine.liveProjectPaths().count == 1)
        print("LIVE_POOL cursor warm new-chat spawn=\(counter.spawnCount)")
    }

    // MARK: - Helpers

    private var isEnabled: Bool {
        ProcessInfo.processInfo.environment[Self.enableVariable] == "1"
    }

    private func requiredProjectPaths() -> (
        claudeA: String,
        claudeB: String,
        codex: String,
        cursor: String
    )? {
        guard let claudeA = Self.projectPath(envKey: Self.claudeProjectAKey),
              let claudeB = Self.projectPath(envKey: Self.claudeProjectBKey),
              let codex = Self.projectPath(envKey: Self.codexProjectKey),
              let cursor = Self.projectPath(envKey: Self.cursorProjectKey)
        else {
            Issue.record("""
                set CODEMIXER_LIVE_CLAUDE_PROJECT_A, CODEMIXER_LIVE_CLAUDE_PROJECT_B, \
                CODEMIXER_LIVE_CODEX_PROJECT, and CODEMIXER_LIVE_CURSOR_PROJECT \
                to trusted project directories
                """)
            return nil
        }
        return (claudeA, claudeB, codex, cursor)
    }

    private static func projectPath(envKey: String) -> String? {
        let env = ProcessInfo.processInfo.environment[envKey]?
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard let env, !env.isEmpty else { return nil }
        return env
    }

    private func makeEngine(counter: CountingTransportFactory) async throws -> AgentEngine {
        await AdapterRegistry.shared.register(id: .claudeCode) { ClaudeAdapter() }
        await AdapterRegistry.shared.register(id: .codex) { CodexAdapter() }
        await AdapterRegistry.shared.register(id: .cursorCLI) { CursorACPAdapter() }

        let engine = AgentEngine(
            seams: .live,
            transportFactory: counter.make
        )
        await engine.bootstrap()
        return engine
    }

    private func standardized(_ path: String) -> String {
        URL(fileURLWithPath: path).standardizedFileURL.path
    }

    private func waitUntil(timeout: Duration, condition: @escaping () async -> Bool) async throws {
        let deadline = ContinuousClock.now + timeout
        while ContinuousClock.now < deadline {
            if await condition() { return }
            try await Task.sleep(for: .milliseconds(250))
        }
        #expect(await condition(), "timed out waiting for live pool condition")
    }

}

/// Counts live transport constructions so pool reuse can be asserted without mocks.
private final class CountingTransportFactory: @unchecked Sendable {
    private let lock = NSLock()
    private(set) var spawnCount = 0

    func make(descriptor: AgentTransportDescriptor,
              launch: AgentTransportLaunchSpec) throws -> any AgentTransport {
        lock.lock()
        spawnCount += 1
        let n = spawnCount
        lock.unlock()
        print("LIVE_POOL spawn#\(n) kind=\(descriptor.kind)")
        return try LiveAgentTransportFactory.make(descriptor: descriptor, launch: launch)
    }
}
