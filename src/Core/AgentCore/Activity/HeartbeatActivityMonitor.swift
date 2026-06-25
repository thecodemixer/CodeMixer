import Foundation
import AgentProtocol

/// Watches the gap between events for the active turn and emits
/// `noEventGap` ticks + escalates `ActivitySubstate`.
///
/// Thresholds are pinned here (not in clients) so the Mac UI, future iOS app,
/// and any automation script see identical escalation timing.
public actor HeartbeatActivityMonitor {

    public static let stillWorkingThreshold = ActivityTiming.stillWorkingThreshold
    public static let probablyStuckThreshold = ActivityTiming.probablyStuckThreshold

    public struct Tick: Sendable {
        public let elapsed: Duration
        public let substate: ActivitySubstate
    }

    private let clock: any AgentClock
    private let onTick: @Sendable (Tick) async -> Void
    private var turnID: UUID?
    private var lastEventAt: ContinuousClock.Instant?
    private var baselineSubstate: ActivitySubstate = .idle
    private var loopTask: Task<Void, Never>?

    public init(clock: any AgentClock,
                onTick: @escaping @Sendable (Tick) async -> Void) {
        self.clock = clock
        self.onTick = onTick
    }

    /// Begin monitoring a new turn. Cancels any prior loop.
    public func startTurn(_ id: UUID, baseline: ActivitySubstate = .awaitingFirstChunk) {
        loopTask?.cancel()
        turnID = id
        baselineSubstate = baseline
        lastEventAt = clock.monotonic()
        loopTask = Task { [weak self] in await self?.run() }
    }

    /// Reset the gap timer — call after every event the engine publishes.
    public func bump(baseline: ActivitySubstate? = nil) {
        lastEventAt = clock.monotonic()
        if let baseline { baselineSubstate = baseline }
    }

    /// End monitoring (idle).
    public func endTurn() {
        loopTask?.cancel()
        loopTask = nil
        turnID = nil
        baselineSubstate = .idle
        lastEventAt = nil
    }

    // MARK: - Private

    private func run() async {
        while !Task.isCancelled, let last = lastEventAt {
            try? await clock.sleep(for: ActivityTiming.noEventPollInterval)
            guard !Task.isCancelled else { return }
            let elapsed = clock.monotonic() - last
            let substate = escalate(from: baselineSubstate, elapsed: elapsed)
            await onTick(Tick(elapsed: elapsed, substate: substate))
        }
    }

    private func escalate(from baseline: ActivitySubstate, elapsed: Duration) -> ActivitySubstate {
        if elapsed >= Self.probablyStuckThreshold { return .probablyStuck }
        if elapsed >= Self.stillWorkingThreshold  { return .stillWorking }
        return baseline
    }
}
