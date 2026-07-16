import Testing
@testable import AgentCore
import AgentProtocol

@Suite("StatusPhraseResolver — priority arbitration")
struct StatusPhraseResolverTests {

    @Test("Higher-priority source overrides lower-priority phrase")
    func priorityOverride() async {
        let resolver = StatusPhraseResolver()
        _ = await resolver.update(.heuristic, phrase: ActivityTiming.thinkingPhrase)
        let winner = await resolver.update(.hookHint, phrase: "Reading file")
        #expect(winner?.0 == .hookHint)
        #expect(winner?.1 == "Reading file")
    }

    @Test("Removing the winning source falls back to next-highest")
    func fallbackOnRemoval() async {
        let resolver = StatusPhraseResolver()
        _ = await resolver.update(.heuristic, phrase: ActivityTiming.thinkingPhrase)
        _ = await resolver.update(.adapterPinned, phrase: "Compacting")
        let winner = await resolver.update(.adapterPinned, phrase: nil)
        #expect(winner?.0 == .heuristic)
        #expect(winner?.1 == ActivityTiming.thinkingPhrase)
    }

    @Test("All four sources respect the documented priority order")
    func fullPriorityOrder() async {
        let resolver = StatusPhraseResolver()

        // Seed lowest two first.
        _ = await resolver.update(.heuristic, phrase: "heuristic")
        _ = await resolver.update(.tuiScrape, phrase: "tui")

        // tuiScrape > heuristic
        let state1 = await (resolver.current, resolver.currentSource)
        #expect(state1.0 == "tui")
        #expect(state1.1 == .tuiScrape)

        // hookHint > tuiScrape
        _ = await resolver.update(.hookHint, phrase: "hook")
        let state2 = await (resolver.current, resolver.currentSource)
        #expect(state2.0 == "hook")
        #expect(state2.1 == .hookHint)

        // adapterPinned > hookHint
        _ = await resolver.update(.adapterPinned, phrase: "pinned")
        let state3 = await (resolver.current, resolver.currentSource)
        #expect(state3.0 == "pinned")
        #expect(state3.1 == .adapterPinned)

        // Lower-priority update while adapterPinned active — winner unchanged.
        let noChange = await resolver.update(.heuristic, phrase: "ignored")
        #expect(noChange == nil)
    }

    @Test("reset() clears all sources and resets to Idle/heuristic")
    func resetClearsAllSources() async {
        let resolver = StatusPhraseResolver()
        _ = await resolver.update(.adapterPinned, phrase: "Busy")
        _ = await resolver.update(.hookHint, phrase: "Reading")
        await resolver.reset()

        let current = await resolver.current
        let source  = await resolver.currentSource
        #expect(current == ActivityTiming.idlePhrase)
        #expect(source == .heuristic)

        // After reset, a low-priority update should win.
        let result = await resolver.update(.heuristic, phrase: ActivityTiming.thinkingPhrase)
        #expect(result?.0 == .heuristic)
        #expect(result?.1 == ActivityTiming.thinkingPhrase)
    }

    @Test("Same source + same phrase returns nil (no change)")
    func noChangeReturnNil() async {
        let resolver = StatusPhraseResolver()
        _ = await resolver.update(.hookHint, phrase: "Reading")
        let second = await resolver.update(.hookHint, phrase: "Reading")
        #expect(second == nil)
    }
}
