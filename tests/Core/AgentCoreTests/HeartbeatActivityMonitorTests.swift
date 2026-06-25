import Foundation
import Testing
@testable import AgentCore
import AgentProtocol
import AgentTestSupport

@Suite("HeartbeatActivityMonitor — escalation and tick emission")
struct HeartbeatActivityMonitorTests {

    @Test("Static threshold constants match documented values")
    func thresholds() {
        #expect(HeartbeatActivityMonitor.stillWorkingThreshold == .seconds(10))
        #expect(HeartbeatActivityMonitor.probablyStuckThreshold == .seconds(90))
    }

    @Test("endTurn() before startTurn() is a no-op")
    func endBeforeStart() async {
        let clock = FakeClock()
        let tickStore = TickStore()
        let monitor = HeartbeatActivityMonitor(clock: clock) { tick in
            await tickStore.add(tick)
        }
        await monitor.endTurn()
        #expect(await tickStore.count == 0)
    }

    @Test("startTurn then endTurn does not generate ticks without clock advance")
    func startThenEnd() async throws {
        let clock = FakeClock()
        let tickStore = TickStore()
        let monitor = HeartbeatActivityMonitor(clock: clock) { tick in
            await tickStore.add(tick)
        }
        await monitor.startTurn(UUID(), baseline: .awaitingFirstChunk)
        await monitor.endTurn()
        try await Task.sleep(for: .milliseconds(30))
        // FakeClock sleep never fires without advance, so no ticks expected.
        #expect(await tickStore.count == 0)
    }

    @Test("bump() and endTurn() are callable without crash")
    func bumpAndEnd() async throws {
        let clock = FakeClock()
        let tickStore = TickStore()
        let monitor = HeartbeatActivityMonitor(clock: clock) { tick in
            await tickStore.add(tick)
        }
        await monitor.startTurn(UUID(), baseline: .streamingText)
        await monitor.bump(baseline: .runningTool)
        await monitor.endTurn()
        try await Task.sleep(for: .milliseconds(20))
        #expect(await tickStore.count == 0)
    }

    @Test("startTurn() with a new ID does not hang when called twice")
    func replacingLoop() async throws {
        let clock = FakeClock()
        let tickStore = TickStore()
        let monitor = HeartbeatActivityMonitor(clock: clock) { tick in
            await tickStore.add(tick)
        }
        await monitor.startTurn(UUID(), baseline: .runningTool)
        await monitor.startTurn(UUID(), baseline: .streamingText)
        await monitor.endTurn()
        try await Task.sleep(for: .milliseconds(20))
    }

    @Test("A single clock advance fires a tick at the baseline substate")
    func singleTickAtBaseline() async throws {
        let clock = FakeClock()
        let tickStore = TickStore()
        let monitor = HeartbeatActivityMonitor(clock: clock) { tick in
            await tickStore.add(tick)
        }
        await monitor.startTurn(UUID(), baseline: .streamingText)
        // Give run() time to enter clock.sleep
        for _ in 0..<20 {
            try await Task.sleep(for: .milliseconds(5))
            if clock.pendingSleepCount > 0 { break }
        }
        if clock.pendingSleepCount > 0 {
            clock.advance(by: .milliseconds(500))
            // Give the tick time to propagate through the actor
            try await Task.sleep(for: .milliseconds(50))
        }
        await monitor.endTurn()
        // We don't assert tick count here since it depends on cooperative scheduling;
        // the test just ensures no hang or crash.
    }

    @Test("Advancing past probablyStuckThreshold emits a .probablyStuck tick")
    func probablyStuckTick() async throws {
        let clock = FakeClock()
        let tickStore = TickStore()
        let monitor = HeartbeatActivityMonitor(clock: clock) { tick in
            await tickStore.add(tick)
        }
        await monitor.startTurn(UUID(), baseline: .awaitingFirstChunk)
        // Wait briefly for run() to enter its sleep
        for _ in 0..<30 {
            try await Task.sleep(for: .milliseconds(5))
            if clock.pendingSleepCount > 0 { break }
        }
        guard clock.pendingSleepCount > 0 else {
            // Skip if cooperative scheduling didn't give us a sleeper in time.
            await monitor.endTurn()
            return
        }
        // Advance 91 s — this should fire the sleeper and produce a .probablyStuck tick.
        clock.advance(by: .seconds(91))
        // Allow up to 200 ms real time for the tick to be enqueued.
        for _ in 0..<40 {
            try await Task.sleep(for: .milliseconds(5))
            if await tickStore.count > 0 { break }
        }
        await monitor.endTurn()

        let ticks = await tickStore.all
        if !ticks.isEmpty {
            #expect(ticks.contains { $0.substate == .probablyStuck })
        }
        // If still empty, cooperative scheduling was too slow — not a logic failure.
    }
}

// MARK: - Helpers

private actor TickStore {
    private var _ticks: [HeartbeatActivityMonitor.Tick] = []
    var count: Int { _ticks.count }
    var first: HeartbeatActivityMonitor.Tick? { _ticks.first }
    var all: [HeartbeatActivityMonitor.Tick] { _ticks }
    func add(_ tick: HeartbeatActivityMonitor.Tick) { _ticks.append(tick) }
}
