import Foundation
import os
import AgentCore

/// Deterministic clock for tests.
///
/// - `now()` and `monotonic()` return whatever the test pinned via `set(now:)`
///   or accumulated via `advance(by:)`.
/// - `sleep(for:)` is virtual: each call suspends until `advance(by:)` (or
///   `set(now:)`) pushes the clock past the requested wake instant. This lets
///   tests compress arbitrarily long timeouts into a single tick.
public final class FakeClock: AgentClock, @unchecked Sendable {

    private final class Sleeper: @unchecked Sendable {
        let wakeAt: ContinuousClock.Instant
        let continuation: CheckedContinuation<Void, any Error>
        var fired: Bool = false
        init(wakeAt: ContinuousClock.Instant, continuation: CheckedContinuation<Void, any Error>) {
            self.wakeAt = wakeAt
            self.continuation = continuation
        }
    }

    private struct State {
        var pinnedNow: Date
        var pinnedMono: ContinuousClock.Instant
        var sleepers: [Sleeper] = []
    }

    private let state: OSAllocatedUnfairLock<State>

    public init(now: Date = Date(timeIntervalSince1970: 1_700_000_000)) {
        self.state = OSAllocatedUnfairLock(initialState: State(pinnedNow: now, pinnedMono: .now))
    }

    public func now() -> Date {
        state.withLock { $0.pinnedNow }
    }

    public func monotonic() -> ContinuousClock.Instant {
        state.withLock { $0.pinnedMono }
    }

    public func sleep(for duration: Duration) async throws {
        try Task.checkCancellation()
        if duration <= .zero { return }
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (cont: CheckedContinuation<Void, any Error>) in
                state.withLock { s in
                    let sleeper = Sleeper(wakeAt: s.pinnedMono.advanced(by: duration),
                                          continuation: cont)
                    s.sleepers.append(sleeper)
                }
            }
        } onCancel: {
            self.cancelAll()
        }
    }

    public func advance(by duration: Duration) {
        let toFire: [Sleeper] = state.withLock { s in
            s.pinnedNow.addTimeInterval(Self.seconds(of: duration))
            s.pinnedMono = s.pinnedMono.advanced(by: duration)
            let now = s.pinnedMono
            var ready: [Sleeper] = []
            s.sleepers.removeAll { sleeper in
                if !sleeper.fired && sleeper.wakeAt <= now {
                    sleeper.fired = true
                    ready.append(sleeper)
                    return true
                }
                return false
            }
            return ready
        }
        for s in toFire { s.continuation.resume() }
    }

    public func set(now: Date) {
        state.withLock { $0.pinnedNow = now }
    }

    private func cancelAll() {
        let toFail: [Sleeper] = state.withLock { s in
            let ss = s.sleepers
            s.sleepers.removeAll()
            return ss
        }
        for s in toFail where !s.fired {
            s.fired = true
            s.continuation.resume(throwing: CancellationError())
        }
    }

    /// Number of tasks currently waiting in `sleep(for:)`. Tests can poll this
    /// to wait for an engine to install its timeout.
    public var pendingSleepCount: Int {
        state.withLock { $0.sleepers.count }
    }

    private static func seconds(of duration: Duration) -> TimeInterval {
        let comps = duration.components
        return Double(comps.seconds) + Double(comps.attoseconds) * 1e-18
    }
}
