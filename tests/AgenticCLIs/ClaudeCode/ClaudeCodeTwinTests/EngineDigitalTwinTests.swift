import Testing
import Foundation
import AgentCore
import AgentProtocol
import AgentTestSupport
import ClaudeCode

/// End-to-end exercise of the engine driven by `ClaudeCodeTwin`.
/// **Fast projection tests** — not full `fake-claude` fidelity; see
/// `FakeClaudeIntegrationTests` for production adapter + spawned twin coverage.
@Suite("Engine + ClaudeCodeTwin", .serialized)
struct EngineDigitalTwinTests {

    @Test("text-only turn emits sessionStarted + textDelta + assistantText + stopped")
    func textOnlyTurn() async throws {
        try await driveTurn(
            scenario: .textOnly(reply: "Hello, world."),
            until: { events in events.contains(where: { $0.isStopped }) },
            assertion: { events in
                #expect(events.contains(where: { $0.isSessionStarted }))
                #expect(events.contains(where: { if case .textDelta = $0 { return true }; return false }))
                #expect(events.contains(where: { if case .assistantText(_, _, let t, let f) = $0 { return f && t == "Hello, world." }; return false }))
                #expect(events.contains(where: { $0.isStopped }))
            }
        )
    }

    @Test("Bash tool turn emits toolStart, toolProgress, toolEnd")
    func bashToolTurn() async throws {
        try await driveTurn(
            scenario: .withBash(command: "ls", stdout: "a\nb\nc", exitCode: 0, reply: "Done."),
            until: { events in events.contains(where: { $0.isStopped }) },
            assertion: { events in
                let starts = events.compactMap { event -> String? in
                    if case .toolStart(_, let name, _, _) = event { return name }; return nil
                }
                let ends = events.compactMap { event -> Bool? in
                    if case .toolEnd(_, let s, _, _) = event { return s }; return nil
                }
                let lines = events.compactMap { event -> String? in
                    if case .toolProgress(_, .bashLine(let l)) = event { return l }; return nil
                }
                #expect(starts.contains("Bash"))
                #expect(ends == [true])
                #expect(lines == ["a", "b", "c"])
            }
        )
    }

    @Test("thinking scenario emits thinkingChunk then thinkingComplete")
    func thinkingTurn() async throws {
        try await driveTurn(
            scenario: .thinkingThenReply(thinking: "considering options",
                                         reply: "Reply!"),
            until: { events in events.contains(where: { $0.isStopped }) },
            assertion: { events in
                #expect(events.contains(where: { if case .thinkingChunk = $0 { return true }; return false }))
                #expect(events.contains(where: { if case .thinkingComplete = $0 { return true }; return false }))
            }
        )
    }

    @Test("permission scenario surfaces permissionRequest")
    func permissionTurn() async throws {
        try await driveTurn(
            scenario: .permissionPrompt(tool: "Bash",
                                        summary: "Run a shell command",
                                        reply: "ok"),
            until: { events in events.contains(where: { $0.isStopped }) },
            assertion: { events in
                #expect(events.contains(where: { if case .permissionRequest = $0 { return true }; return false }))
            }
        )
    }

    @Test("crash scenario surfaces error event")
    func crashTurn() async throws {
        try await driveTurn(
            scenario: .crash(partial: "thinking…"),
            until: { events in events.contains(where: { $0.isStopped }) },
            assertion: { events in
                #expect(events.contains(where: { if case .error = $0 { return true }; return false }))
            }
        )
    }

    @Test("usageOnly scenario emits .usage event")
    func usageTurn() async throws {
        try await driveTurn(
            scenario: .usageOnly(inputTokens: 100, outputTokens: 50, costUSD: 0.001),
            until: { events in events.contains(where: { if case .usage = $0 { return true }; return false }) },
            assertion: { events in
                #expect(events.contains(where: { if case .usage = $0 { return true }; return false }))
            }
        )
    }

    @Test("needsAuth scenario emits .authURL event")
    func needsAuthTurn() async throws {
        let authURL = URL(string: "https://auth.example.com/code?code=abc")!
        try await driveTurn(
            scenario: .needsAuth(url: authURL),
            until: { events in events.contains(where: { if case .authURL = $0 { return true }; return false }) },
            assertion: { events in
                #expect(events.contains(where: { if case .authURL = $0 { return true }; return false }))
            }
        )
    }

    @Test("withEdit scenario emits .fileTouched(.hookReported)")
    func withEditTurn() async throws {
        try await driveTurn(
            scenario: .withEdit(path: "/tmp/foo.swift", diff: "+let x = 1", reply: "Done."),
            until: { events in events.contains(where: { $0.isStopped }) },
            assertion: { events in
                let touched = events.contains { event in
                    if case let .fileTouched(_, kind) = event { return kind == .hookReported }
                    return false
                }
                #expect(touched)
            }
        )
    }

    // MARK: - Shared driver

    /// Builds an engine + twin, drives a single turn, and tears everything
    /// down. Uses `withTimeout` so a stuck stream cannot hang the suite.
    private func driveTurn(scenario: ClaudeCodeTwin.Scenario,
                           until: @escaping @Sendable ([AgentEvent]) -> Bool,
                           assertion: ([AgentEvent]) -> Void) async throws {
        let seams = Seams.live
        let engine = AgentEngine(seams: seams)
        await engine.bootstrap()

        let twin = ClaudeCodeTwin(configuration: .init(scenario: scenario))
        let workspace = FileManager.default.temporaryDirectory
            .appendingPathComponent("codemixer-twin-\(UUID().uuidString)", isDirectory: true)
        try? FileManager.default.createDirectory(at: workspace, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: workspace) }

        let bus = engine.bus
        let sub = await bus.subscribe()

        try await engine.start(adapter: twin, workspace: workspace)

        // Collect events with a hard deadline so a flaky turn never hangs.
        let events: [AgentEvent]
        do {
            events = try await withTimeout(.seconds(5)) {
                var collected: [AgentEvent] = []
                for await event in sub.stream {
                    collected.append(event)
                    if until(collected) { break }
                    if collected.count > 256 { break }
                }
                return collected
            }
        } catch is TimeoutError {
            events = []
        }

        await bus.unsubscribe(sub.id)
        await engine.shutdown(reason: .naturalExit)
        await bus.shutdown()

        assertion(events)
    }
}

private extension AgentEvent {
    var isSessionStarted: Bool { if case .sessionStarted = self { return true } else { return false } }
    var isStopped:        Bool { if case .stopped        = self { return true } else { return false } }
}
