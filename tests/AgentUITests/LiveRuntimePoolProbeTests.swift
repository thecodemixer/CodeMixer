import Foundation
import Testing
@testable import AgentUI
@testable import AgentCore
import AgentProtocol
import ClaudeCode
import Codex
import ACPCLIs

/// Live probe of the sticky runtime pool: project A → B → A reuse, Claude
/// New Chat + session switch without respawn, Codex/Cursor warm session switch.
///
/// ```bash
/// CODEMIXER_LIVE_RUNTIME_POOL=1 \
///   swift test --no-parallel --filter LiveRuntimePoolProbeTests
/// ```
@Suite("Live runtime pool — project and session switches", .serialized)
struct LiveRuntimePoolProbeTests {

    private static let enableVariable = "CODEMIXER_LIVE_RUNTIME_POOL"

    /// Claude projects under the user's hiya workspace (two slots).
    private static let claudeProjectA = "/Users/hari/Documents/codemixer workspace/hiya"
    private static let claudeProjectB = "/Users/hari/Documents/codemixer workspace/hiya/cla"
    /// Codex project for warm in-process session switch.
    private static let codexProject = "/Users/hari/Documents/codemixer workspace/hiya/code"
    /// Cursor ACP project for warm session switch.
    private static let cursorProject = "/Users/hari/Documents/codemixer workspace/hiya/cur"

    @Test("Claude cross-project round trip parks and reuses without a third spawn")
    func claudeCrossProjectReuse() async throws {
        guard isEnabled else { return }
        let counter = CountingTransportFactory()
        let engine = try await makeEngine(counter: counter)
        defer { Task { await engine.shutdown(reason: .naturalExit) } }

        try await engine.send(.openProject(path: Self.claudeProjectA, resumeSessionID: nil))
        try await waitUntil(timeout: .seconds(90)) {
            await engine.liveProjectPaths().contains(standardized(Self.claudeProjectA))
                && counter.spawnCount == 1
        }
        #expect(counter.spawnCount == 1)
        print("LIVE_POOL claude A open spawn=\(counter.spawnCount) paths=\(await engine.liveProjectPaths())")

        try await engine.send(.openProject(path: Self.claudeProjectB, resumeSessionID: nil))
        try await waitUntil(timeout: .seconds(90)) {
            let paths = await engine.liveProjectPaths()
            return paths.contains(standardized(Self.claudeProjectA))
                && paths.contains(standardized(Self.claudeProjectB))
                && counter.spawnCount == 2
        }
        #expect(counter.spawnCount == 2)
        print("LIVE_POOL claude B open spawn=\(counter.spawnCount) paths=\(await engine.liveProjectPaths())")

        try await engine.send(.openProject(path: Self.claudeProjectA, resumeSessionID: nil))
        try await waitUntil(timeout: .seconds(60)) {
            await engine.liveProjectPaths().count == 2
        }
        #expect(counter.spawnCount == 2, "returning to A must reuse the parked Claude PTY")
        let paths = await engine.liveProjectPaths()
        #expect(paths.contains(standardized(Self.claudeProjectA)))
        #expect(paths.contains(standardized(Self.claudeProjectB)))
        print("LIVE_POOL claude A reuse spawn=\(counter.spawnCount) paths=\(paths)")
    }

    @Test("Claude new-chat and session switch reuse the same PTY")
    func claudeSessionReuse() async throws {
        guard isEnabled else { return }
        let counter = CountingTransportFactory()
        let engine = try await makeEngine(counter: counter)
        defer { Task { await engine.shutdown(reason: .naturalExit) } }

        let sub = await engine.bus.subscribe()
        defer { Task { await engine.bus.unsubscribe(sub.id) } }

        try await engine.send(.openProject(path: Self.claudeProjectA, resumeSessionID: nil))
        try await waitUntil(timeout: .seconds(90)) { counter.spawnCount == 1 }
        let boundID = await waitForBoundSessionID(in: sub.stream, timeout: .seconds(90))
        guard let boundID, !boundID.isEmpty else {
            Issue.record("Claude never published a SessionStart id — cannot probe session reuse")
            return
        }
        #expect(await engine.liveProjectPaths().count == 1)
        print("LIVE_POOL claude session#1 spawn=\(counter.spawnCount) bound=\(boundID)")

        // New Chat must keep the same PTY and send /clear in-process.
        try await engine.send(.openProject(path: Self.claudeProjectA, resumeSessionID: nil))
        try await Task.sleep(for: .seconds(3))
        #expect(counter.spawnCount == 1, "Claude New Chat must reuse the project PTY")
        #expect(await engine.liveProjectPaths().count == 1)
        print("LIVE_POOL claude new-chat reuse spawn=\(counter.spawnCount)")

        let other = ClaudeSessionLister.summaries(
            workspace: URL(fileURLWithPath: Self.claudeProjectA),
            claudeDirectory: Seams.live.environment.claudeDirectory,
            fileSystem: Seams.live.fileSystem
        ).first { $0.id != boundID }
        if let other {
            try await engine.send(.openProject(path: Self.claudeProjectA, resumeSessionID: other.id))
            try await Task.sleep(for: .seconds(4))
            #expect(counter.spawnCount == 1, "Claude session switch must reuse the project PTY")
            #expect(await engine.liveProjectPaths().count == 1)
            print("LIVE_POOL claude session switch → \(other.id) spawn=\(counter.spawnCount)")
        } else {
            print("LIVE_POOL claude no second on-disk session; skip resume-id reuse check")
        }
    }

    @Test("Codex cross-project then return reuses the Codex slot; new chat stays warm")
    func codexCrossProjectAndWarmNewChat() async throws {
        guard isEnabled else { return }
        let counter = CountingTransportFactory()
        let engine = try await makeEngine(counter: counter)
        defer { Task { await engine.shutdown(reason: .naturalExit) } }

        try await engine.send(.openProject(path: Self.codexProject, resumeSessionID: nil))
        try await waitUntil(timeout: .seconds(90)) {
            await engine.liveProjectPaths().contains(standardized(Self.codexProject))
                && counter.spawnCount == 1
        }
        print("LIVE_POOL codex open spawn=\(counter.spawnCount)")

        try await engine.send(.openProject(path: Self.claudeProjectA, resumeSessionID: nil))
        try await waitUntil(timeout: .seconds(90)) { counter.spawnCount == 2 }
        #expect(await engine.liveProjectPaths().count == 2)
        print("LIVE_POOL codex→claude spawn=\(counter.spawnCount) paths=\(await engine.liveProjectPaths())")

        try await engine.send(.openProject(path: Self.codexProject, resumeSessionID: nil))
        try await waitUntil(timeout: .seconds(60)) {
            await engine.liveProjectPaths().contains(standardized(Self.codexProject))
        }
        #expect(counter.spawnCount == 2, "returning to Codex must reuse the parked App Server")
        print("LIVE_POOL codex reuse spawn=\(counter.spawnCount)")

        // New chat on Codex should stay in-process (thread/start), no third spawn.
        try await engine.send(.openProject(path: Self.codexProject, resumeSessionID: nil))
        try await Task.sleep(for: .seconds(3))
        #expect(counter.spawnCount == 2, "Codex new chat must not respawn")
        #expect(await engine.liveProjectPaths().count == 2)
        print("LIVE_POOL codex warm new-chat spawn=\(counter.spawnCount) paths=\(await engine.liveProjectPaths())")
    }

    @Test("Cursor ACP new chat reuses the project process")
    func cursorWarmNewChat() async throws {
        guard isEnabled else { return }
        let counter = CountingTransportFactory()
        let engine = try await makeEngine(counter: counter)
        defer { Task { await engine.shutdown(reason: .naturalExit) } }

        try await engine.send(.openProject(path: Self.cursorProject, resumeSessionID: nil))
        try await waitUntil(timeout: .seconds(90)) { counter.spawnCount == 1 }
        print("LIVE_POOL cursor open spawn=\(counter.spawnCount)")

        try await engine.send(.openProject(path: Self.cursorProject, resumeSessionID: nil))
        try await Task.sleep(for: .seconds(4))
        #expect(counter.spawnCount == 1, "Cursor new chat must warm-switch without respawn")
        #expect(await engine.liveProjectPaths().count == 1)
        print("LIVE_POOL cursor warm new-chat spawn=\(counter.spawnCount)")
    }

    // MARK: - Helpers

    private var isEnabled: Bool {
        ProcessInfo.processInfo.environment[Self.enableVariable] == "1"
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

    private func waitForBoundSessionID(in stream: AsyncStream<MulticastEventBus.HistoryEntry>,
                                        timeout: Duration) async -> String? {
        let deadline = ContinuousClock.now + timeout
        for await entry in stream {
            if case .sessionStarted(let id, _, _) = entry.event, !id.isEmpty {
                return id
            }
            if ContinuousClock.now >= deadline { break }
        }
        return nil
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
