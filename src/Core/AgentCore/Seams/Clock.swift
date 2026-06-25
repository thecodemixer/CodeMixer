import Foundation

/// Source of wall-clock time.
///
/// Every type that asks "what time is it?" takes one of these in its
/// initializer. Production code uses `SystemClock`; tests use `FakeClock`
/// from `AgentTestSupport`. Domain code never reads `Date()` directly.
public protocol AgentClock: Sendable {
    /// Current wall-clock instant.
    func now() -> Date

    /// Monotonic instant, suitable for measuring elapsed durations across
    /// system sleep boundaries.
    func monotonic() -> ContinuousClock.Instant

    /// Suspend the current task for at least `duration`. Honours cancellation.
    func sleep(for duration: Duration) async throws
}

/// Production implementation.
public struct SystemClock: AgentClock {
    public init() {}

    public func now() -> Date { Date() }

    public func monotonic() -> ContinuousClock.Instant {
        ContinuousClock.now
    }

    public func sleep(for duration: Duration) async throws {
        try await Task.sleep(for: duration)
    }
}
