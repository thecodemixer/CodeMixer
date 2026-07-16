import Testing
import Foundation
@testable import AgentCore
import AgentProtocol
import AgentTestSupport

@Suite("AgentEngine integration")
struct EngineIntegrationTests {

    @Test func prefsCommandRoundTrip() async throws {
        let fs = InMemoryFileSystem()
        let env = FakeEnvironment()
        let seams = Seams.fake(environment: env, fileSystem: fs)
        let engine = AgentEngine(seams: seams)
        await engine.bootstrap()

        // Drive the engine without a real session — the prefs commands are
        // out-of-band and don't require an adapter to be bound. We seed an
        // adapter via the public start API to satisfy the invariant guard.
        let bus = engine.bus
        let sub = await bus.subscribe()

        let collector = Task<[AgentEvent], Never> {
            var out: [AgentEvent] = []
            for await entry in sub.stream {
                out.append(entry.event)
                if out.count >= 2 { break }
            }
            return out
        }

        // Start a no-op adapter session (the spawn will fail because the
        // fake env has no shell environment seeded, but prefs persist regardless).
        let adapter = MockAdapter()
        try? await engine.start(adapter: adapter,
                                workspace: URL(fileURLWithPath: env.appSupportDirectory.path))

        let cmd1: AgentCommand = .updateAppearancePref(key: .theme, value: .string("midnight"))
        try await engine.send(cmd1)
        let cmd2: AgentCommand = .updateAutoApprovalRules([
            AutoApprovalRule(match: "Bash echo *", decision: .allow)
        ])
        try await engine.send(cmd2)

        try? await Task.sleep(for: .milliseconds(50))
        await bus.unsubscribe(sub.id)
        let events = await collector.value

        // We always see at least sessionStarted; rest is best-effort.
        #expect(events.contains { if case .sessionStarted = $0 { return true }; return false }
                || events.contains { if case .appearancePrefChanged = $0 { return true }; return false }
                || events.contains { if case .prefsChanged = $0 { return true }; return false })

        let state = await engine.prefs.state()
        #expect(state.appearance.theme == "midnight")
        #expect(state.autoApprovalRules.count == 1)

        await engine.shutdown(reason: .naturalExit)
    }

    @Test func snapshotServiceReturnsPrefsJSON() async throws {
        let fs = InMemoryFileSystem()
        let env = FakeEnvironment()
        let prefs = PrefsStore(environment: env, fileSystem: fs)
        await prefs.load()
        try await prefs.updateAppearance(.theme, value: .string("solarized"))

        let sessions = SessionStore(environment: env, fileSystem: fs)
        await sessions.load()

        let service = SnapshotService(prefs: prefs, sessions: sessions)
        let data = await service.snapshot(.prefs)
        let json = String(data: data, encoding: .utf8) ?? ""
        #expect(json.contains("\"theme\":\"solarized\""))
    }

    @Test("terminal snapshot is empty before a PTY session starts")
    func terminalSnapshotIsEmptyBeforeSession() async {
        let engine = AgentEngine(seams: .fake())
        await engine.bootstrap()

        let snapshot = await engine.terminalSnapshotText()
        #expect(snapshot.isEmpty)
    }
}
