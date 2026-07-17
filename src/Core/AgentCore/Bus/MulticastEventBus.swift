import Foundation
import OSLog

/// Fan-out hub for `AgentEvent`s.
///
/// Subscribers each receive an `AsyncStream<AgentEvent>` independent of any
/// other subscriber's consumption speed (back-pressure is per-stream:
/// `.bufferingOldest(historyLimit)` drops the oldest pending event for that
/// subscriber when its queue is full, rather than stalling the bus). On
/// subscribe, the client also receives the rolling `StreamBufferDefaults.eventHistory`
/// recent context.
///
/// Each published event is tagged with a bus-assigned `UUID` in
/// `HistoryEntry`. Wire consumers (remote clients in the client-role sense —
/// see `docs/architecture.md` §4.1) store the last `entryID` they received
/// and pass it back in the `subscribe` frame on reconnect; the bus then
/// replays only the slice they missed — avoiding duplicate delivery.
public actor MulticastEventBus {

    /// One entry in the rolling history ring-buffer.
    public struct HistoryEntry: Sendable {
        /// Bus-assigned sequence identifier. Clients should treat this as an
        /// opaque token and pass it back as `lastSeenEventID` on reconnect.
        public let id: UUID
        public let event: AgentEvent
    }

    public struct Subscription: Sendable {
        public let id: UUID
        public let stream: AsyncStream<HistoryEntry>
    }

    private let log = Logger(subsystem: AppIdentity.logSubsystem, category: "EventBus")
    private let random: any RandomSource
    private let historyLimit: Int
    private var history: [HistoryEntry] = []
    private var continuations: [UUID: AsyncStream<HistoryEntry>.Continuation] = [:]

    public init(historyLimit: Int = StreamBufferDefaults.eventHistory,
                random: any RandomSource = SystemRandomSource()) {
        precondition(historyLimit > 0)
        self.historyLimit = historyLimit
        self.random = random
    }

    // MARK: - Subscription

    /// Subscribe to events. The returned stream first replays the full rolling
    /// history (oldest-first), then continues with live events.
    ///
    /// Use this for in-process consumers (Mac UI, tests) that have no prior
    /// event checkpoint. For reconnecting remote clients that know which event
    /// they last received, use `subscribe(after:)` to receive only the delta.
    public func subscribe() -> Subscription {
        return subscribe(after: nil)
    }

    /// Subscribe with selective history replay.
    ///
    /// - Parameter afterID: The last `HistoryEntry.id` the caller already
    ///   received.  If `nil` or unknown, the full history is replayed (same
    ///   as `subscribe()`).  If the ID is found in the ring-buffer, only
    ///   entries **after** it are replayed, which is O(1) additional bytes
    ///   for a client that just WiFi-dropped mid-turn.
    public func subscribe(after afterID: UUID?) -> Subscription {
        let id = random.uuid()
        var continuation: AsyncStream<HistoryEntry>.Continuation!
        let stream = AsyncStream(bufferingPolicy: .bufferingOldest(historyLimit)) { c in
            continuation = c
            // Self-clean when the consumer cancels so UI/debug tails do not leak.
            c.onTermination = { [weak self] _ in
                Task { await self?.unsubscribe(id) }
            }
        }

        let slice: ArraySlice<HistoryEntry>
        if let afterID,
           let idx = history.firstIndex(where: { $0.id == afterID }) {
            // Replay only the delta after the last-seen entry.
            slice = history[(history.index(after: idx))...]
        } else {
            // Unknown checkpoint (or nil): replay full history.
            // Callers that care about expired checkpoints use subscribeWithOutcome.
            slice = history[...]
        }
        for entry in slice { continuation.yield(entry) }

        continuations[id] = continuation
        log.debug("subscriber \(id, privacy: .public) added afterID=\(String(describing: afterID), privacy: .public) replayed=\(slice.count, privacy: .public) total=\(self.continuations.count, privacy: .public)")
        return Subscription(id: id, stream: stream)
    }

    /// Outcome of a checkpointed subscribe — used by remote clients.
    public enum SubscribeOutcome: Sendable, Equatable {
        case fresh
        case resumed
        case checkpointExpired
    }

    /// Subscribe and report whether history was fully replayed, resumed from
    /// a known checkpoint, or the checkpoint had fallen out of the ring.
    public func subscribeWithOutcome(after afterID: UUID?) -> (Subscription, SubscribeOutcome) {
        let outcome: SubscribeOutcome
        if let afterID {
            if history.contains(where: { $0.id == afterID }) {
                outcome = .resumed
            } else if history.isEmpty {
                outcome = .fresh
            } else {
                outcome = .checkpointExpired
            }
        } else {
            outcome = .fresh
        }
        return (subscribe(after: afterID), outcome)
    }

    // MARK: - Publish / unsubscribe

    /// Unsubscribe. The stream is terminated.
    public func unsubscribe(_ id: UUID) {
        if let c = continuations.removeValue(forKey: id) {
            c.finish()
            log.debug("subscriber \(id, privacy: .public) removed; total=\(self.continuations.count, privacy: .public)")
        }
    }

    /// Publish an event to every current subscriber and append to history.
    /// Returns the bus-assigned `HistoryEntry.id` so callers can track the
    /// latest checkpoint without re-reading the history.
    @discardableResult
    public func publish(_ event: AgentEvent) -> UUID {
        let entryID = random.uuid()
        let entry = HistoryEntry(id: entryID, event: event)
        history.append(entry)
        if history.count > historyLimit {
            history.removeFirst(history.count - historyLimit)
        }
        for c in continuations.values {
            c.yield(entry)
        }
        return entryID
    }

    /// Tear down: finish every subscriber stream and clear history.
    public func shutdown() {
        for c in continuations.values { c.finish() }
        continuations.removeAll(keepingCapacity: false)
        history.removeAll(keepingCapacity: false)
    }

    // MARK: - Accessors

    /// Current subscriber count — useful for the UI's "connected clients" chip.
    public var subscriberCount: Int { continuations.count }

    /// The `HistoryEntry.id` of the most recently published event, or `nil`
    /// if no events have been published yet. Remote clients store this value
    /// and pass it back on reconnect.
    public var lastPublishedID: UUID? { history.last?.id }

    /// A snapshot of the current ring-buffer, oldest-first.
    public var historySnapshot: [HistoryEntry] { history }
}
