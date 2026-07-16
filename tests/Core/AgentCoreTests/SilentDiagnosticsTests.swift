import Foundation
import Testing
@testable import AgentCore
import AgentTestSupport

@Suite("SilentDiagnostics — ring buffer and recording")
struct SilentDiagnosticsTests {

    @Test("record appends entries oldest-first in snapshot")
    func recordAppends() async {
        let clock = FakeClock()
        let random = FakeRandomSource()
        let diag = SilentDiagnostics(clock: clock, random: random, capacity: 8)
        await diag.clear()

        _ = await diag.record(kind: .prefsQuietReset,
                              owner: "PrefsStore",
                              summary: "first")
        _ = await diag.record(kind: .sessionsQuietReset,
                              owner: "SessionStore",
                              summary: "second")

        let snap = await diag.snapshot()
        #expect(snap.count == 2)
        #expect(snap[0].summary == "first")
        #expect(snap[1].summary == "second")
        #expect(snap[0].kind == .prefsQuietReset)
        #expect(snap[1].owner == "SessionStore")
    }

    @Test("ring evicts oldest records when capacity is exceeded")
    func ringBound() async {
        let clock = FakeClock()
        let random = FakeRandomSource()
        let capacity = 3
        let diag = SilentDiagnostics(clock: clock, random: random, capacity: capacity)
        await diag.clear()

        for i in 0..<5 {
            _ = await diag.record(kind: .other,
                                  owner: "Test",
                                  summary: "entry-\(i)")
        }

        let snap = await diag.snapshot()
        #expect(snap.count == capacity)
        #expect(snap.map(\.summary) == ["entry-2", "entry-3", "entry-4"])
    }

    @Test("clear removes all retained records")
    func clearEmptiesRing() async {
        let diag = SilentDiagnostics(clock: FakeClock(),
                                     random: FakeRandomSource(),
                                     capacity: 4)
        _ = await diag.record(kind: .other, owner: "Test", summary: "x")
        await diag.clear()
        #expect(await diag.snapshot().isEmpty)
    }
}
