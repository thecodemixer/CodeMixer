import Foundation
import Testing
@testable import AgentTestSupport

@Suite("FakeClock — virtual sleep")
struct FakeClockTests {

    @Test("now() returns the pinned date")
    func nowReturnsPinned() {
        let pinned = Date(timeIntervalSince1970: 1_000_000)
        let clock = FakeClock(now: pinned)
        #expect(clock.now() == pinned)
    }

    @Test("set(now:) updates the pinned date")
    func setNowUpdates() {
        let clock = FakeClock()
        let target = Date(timeIntervalSince1970: 2_000_000)
        clock.set(now: target)
        #expect(clock.now() == target)
    }

    @Test("advance(by:) moves now() forward by the duration")
    func advanceMovesNow() {
        let clock = FakeClock(now: Date(timeIntervalSince1970: 0))
        clock.advance(by: .seconds(60))
        #expect(clock.now().timeIntervalSince1970 == 60)
    }

    @Test("sleep(for:) suspends until advance(by:) covers it")
    func sleepWakesOnAdvance() async throws {
        let clock = FakeClock()
        let done = SendableBox<Bool>(false)
        let task = Task {
            try await clock.sleep(for: .seconds(10))
            await done.set(true)
        }
        try await spinUntil { clock.pendingSleepCount == 1 }
        #expect(await done.value == false)
        clock.advance(by: .seconds(11))
        try await task.value
        #expect(await done.value == true)
    }

    @Test("sleep(for: 0) returns immediately")
    func zeroSleepReturns() async throws {
        let clock = FakeClock()
        try await clock.sleep(for: .zero)
        try await clock.sleep(for: .milliseconds(-1))
    }

    @Test("cancellation wakes a sleeper with CancellationError")
    func cancellationWakes() async throws {
        let clock = FakeClock()
        let task = Task {
            do { try await clock.sleep(for: .seconds(60)); return "ok" }
            catch is CancellationError { return "cancelled" }
            catch { return "other" }
        }
        try await spinUntil { clock.pendingSleepCount == 1 }
        task.cancel()
        let result = await task.value
        #expect(result == "cancelled")
    }

    @Test("multiple sleepers wake in monotonic order")
    func multipleSleepers() async throws {
        let clock = FakeClock()
        let log = SendableBox<[String]>([])
        let a = Task { try await clock.sleep(for: .seconds(1)); await log.append("a") }
        let b = Task { try await clock.sleep(for: .seconds(2)); await log.append("b") }
        try await spinUntil { clock.pendingSleepCount == 2 }
        clock.advance(by: .seconds(3))
        try await a.value
        try await b.value
        let entries = await log.value
        #expect(Set(entries) == ["a", "b"])
    }

    private func spinUntil(_ condition: @Sendable () -> Bool,
                           timeoutNanoseconds: UInt64 = 2_000_000_000) async throws {
        let start = ContinuousClock.now
        while !condition() {
            if start.duration(to: .now) > .milliseconds(2_000) {
                throw CancellationError()
            }
            try await Task.sleep(nanoseconds: 1_000_000)
        }
    }
}

/// Small actor-backed mutable box for collecting test side effects.
actor SendableBox<T: Sendable> {
    private(set) var value: T
    init(_ initial: T) { self.value = initial }
    func set(_ v: T) { value = v }
    func append<E>(_ element: E) where T == [E] {
        value.append(element)
    }
}
