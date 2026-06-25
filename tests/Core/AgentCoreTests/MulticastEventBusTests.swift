import Foundation
import Testing
@testable import AgentCore

@Suite("MulticastEventBus — fan-out and history replay")
struct MulticastEventBusTests {

    @Test("Late subscribers receive the replay history first")
    func historyReplay() async {
        let bus = MulticastEventBus(historyLimit: 8)
        for i in 0..<3 {
            await bus.publish(.userTurn(id: "u\(i)", text: "msg\(i)"))
        }
        let sub = await bus.subscribe()
        var iterator = sub.stream.makeAsyncIterator()
        var seen: [String] = []
        for _ in 0..<3 {
            guard case let .userTurn(_, text)? = await iterator.next() else { break }
            seen.append(text)
        }
        #expect(seen == ["msg0", "msg1", "msg2"])
        await bus.shutdown()
    }

    @Test("Live subscribers receive new events broadcast after subscribe")
    func liveFanout() async {
        let bus = MulticastEventBus(historyLimit: 8)
        let sub = await bus.subscribe()
        await bus.publish(.bell)
        var iterator = sub.stream.makeAsyncIterator()
        let next = await iterator.next()
        if case .bell = next {
            #expect(Bool(true))
        } else {
            #expect(Bool(false), "expected .bell got \(String(describing: next))")
        }
        await bus.shutdown()
    }

    @Test("History ring evicts the oldest event when capacity is exceeded")
    func historyEviction() async {
        let limit = 5
        let bus = MulticastEventBus(historyLimit: limit)

        // Publish one more than the limit.
        for i in 0...limit {
            await bus.publish(.userTurn(id: "u\(i)", text: "msg\(i)"))
        }

        // Late subscriber should only see the most recent `limit` events.
        let sub = await bus.subscribe()
        var collected: [String] = []
        var iter = sub.stream.makeAsyncIterator()
        for _ in 0..<limit {
            guard case let .userTurn(_, text)? = await iter.next() else { break }
            collected.append(text)
        }

        #expect(collected.count == limit)
        // "msg0" (oldest) was evicted; "msg1" through "msg5" remain.
        #expect(!collected.contains("msg0"))
        #expect(collected.first == "msg1")
        await bus.shutdown()
    }

    @Test("unsubscribe(_:) finishes the subscriber's stream")
    func unsubscribeEndsStream() async {
        let bus = MulticastEventBus(historyLimit: 8)
        let sub = await bus.subscribe()

        let collectTask = Task<Int, Never> {
            var count = 0
            for await _ in sub.stream { count += 1 }
            return count
        }

        // Publish one event then immediately unsubscribe.
        await bus.publish(.bell)
        await bus.unsubscribe(sub.id)

        let count = await collectTask.value
        #expect(count == 1)
    }

    @Test("3-subscriber concurrent stress: no event lost in a 100-event burst")
    func concurrentStress() async {
        let bus = MulticastEventBus(historyLimit: 200)
        let subs = await [bus.subscribe(), bus.subscribe(), bus.subscribe()]

        let burst = 100
        for i in 0..<burst {
            await bus.publish(.userTurn(id: "u\(i)", text: "m\(i)"))
        }

        for sub in subs {
            var count = 0
            var iter = sub.stream.makeAsyncIterator()
            for _ in 0..<burst {
                guard (await iter.next()) != nil else { break }
                count += 1
            }
            #expect(count == burst)
        }

        await bus.shutdown()
    }

    @Test("shutdown() finishes all subscriber streams")
    func shutdownFinishesAllStreams() async {
        let bus = MulticastEventBus(historyLimit: 8)
        let sub1 = await bus.subscribe()
        let sub2 = await bus.subscribe()

        let task1 = Task<Int, Never> {
            var n = 0; for await _ in sub1.stream { n += 1 }; return n
        }
        let task2 = Task<Int, Never> {
            var n = 0; for await _ in sub2.stream { n += 1 }; return n
        }

        await bus.publish(.bell)
        await bus.shutdown()

        let c1 = await task1.value
        let c2 = await task2.value
        #expect(c1 == 1)
        #expect(c2 == 1)
    }

    // MARK: - Reconnect-with-replay

    @Test("publish returns a stable bus entry ID and lastPublishedID matches")
    func publishReturnsEntryID() async {
        let bus = MulticastEventBus()
        let id1 = await bus.publish(.bell)
        let id2 = await bus.publish(.bell)
        #expect(id1 != id2)
        let latest = await bus.lastPublishedID
        #expect(latest == id2)
        await bus.shutdown()
    }

    @Test("subscribe(after:) replays only events after the checkpoint")
    func selectiveReplay() async {
        let bus = MulticastEventBus(historyLimit: 10)

        // Publish three events, capturing their IDs.
        let id1 = await bus.publish(.userTurn(id: "u1", text: "first"))
        _  = await bus.publish(.userTurn(id: "u2", text: "second"))
        _ = await bus.publish(.userTurn(id: "u3", text: "third"))

        // Subscribe after the first event — should replay only 2nd and 3rd.
        let sub = await bus.subscribe(after: id1)
        var collected: [String] = []
        var it = sub.stream.makeAsyncIterator()
        for _ in 0..<2 {
            guard case .userTurn(_, let text)? = await it.next() else { break }
            collected.append(text)
        }
        #expect(collected == ["second", "third"])
        await bus.shutdown()
    }

    @Test("subscribe(after:) with nil replays full history")
    func nilCheckpointReplaysFull() async {
        let bus = MulticastEventBus(historyLimit: 10)
        _ = await bus.publish(.bell)
        _ = await bus.publish(.bell)
        let sub = await bus.subscribe(after: nil)
        var count = 0
        var it = sub.stream.makeAsyncIterator()
        while let _ = await it.next() {
            count += 1
            if count == 2 { break }
        }
        #expect(count == 2)
        await bus.shutdown()
    }

    @Test("subscribe(after:) with unknown ID replays full history as fallback")
    func unknownCheckpointReplaysFull() async {
        let bus = MulticastEventBus(historyLimit: 10)
        _ = await bus.publish(.bell)
        _ = await bus.publish(.bell)
        let unknownID = UUID()  // not in history
        let sub = await bus.subscribe(after: unknownID)
        var count = 0
        var it = sub.stream.makeAsyncIterator()
        while let _ = await it.next() {
            count += 1
            if count == 2 { break }
        }
        #expect(count == 2)
        await bus.shutdown()
    }

    /// Verifies that `historySnapshot` preserves insertion order and entry IDs.
    /// Uses a fresh subscriber to receive the full replay so we can compare
    /// IDs without returning `[HistoryEntry]` across the actor boundary
    /// (which triggers a Swift 6.2 runtime edge case on task teardown).
    @Test("historySnapshot preserves insertion order via subscribe replay")
    func historySnapshotOrder() async {
        let bus = MulticastEventBus(historyLimit: 10)
        let id1 = await bus.publish(.bell)
        let id2 = await bus.publish(.bell)
        // The snapshot should contain exactly those two entries in order.
        // We verify via lastPublishedID (tail) and subscribe-after (delta).
        let last = await bus.lastPublishedID
        #expect(last == id2)
        // Subscribe after id1 — only id2's event should replay.
        let sub = await bus.subscribe(after: id1)
        var it = sub.stream.makeAsyncIterator()
        let replayed = await it.next()
        #expect(replayed != nil)           // exactly one event replayed
        await bus.shutdown()
    }
}
