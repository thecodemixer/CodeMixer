import Testing
@testable import AgentUI

@Suite("Conversation auto-scroll gate")
struct ConversationAutoScrollGateTests {

    @Test("live-scroll pause is blocked only while programmatic ignore is armed")
    func liveScrollPauseRules() {
        #expect(ConversationAutoScrollGate.shouldAcceptLiveScroll(
            isFollowing: true, ignoringProgrammaticLiveScroll: false))
        #expect(!ConversationAutoScrollGate.shouldAcceptLiveScroll(
            isFollowing: true, ignoringProgrammaticLiveScroll: true))
        #expect(!ConversationAutoScrollGate.shouldAcceptLiveScroll(
            isFollowing: false, ignoringProgrammaticLiveScroll: false))
    }

    @Test("definite user scroll wins whenever follow is on")
    func definiteUserScrollWins() {
        #expect(ConversationAutoScrollGate.definiteUserScrollAlwaysWins(isFollowing: true))
        #expect(!ConversationAutoScrollGate.definiteUserScrollAlwaysWins(isFollowing: false))
    }

    @MainActor
    @Test("wheel gesture pauses even during programmatic ignore window")
    func definiteScrollBeatsProgrammaticIgnore() {
        let controller = ConversationAutoScrollController()
        controller.beginProgrammaticScroll()
        #expect(controller.isIgnoringProgrammaticLiveScroll)
        #expect(!controller.notePossibleUserLiveScroll())
        #expect(controller.isFollowing)

        #expect(controller.noteDefiniteUserScroll())
        #expect(!controller.isFollowing)
        #expect(!controller.isIgnoringProgrammaticLiveScroll)
        #expect(controller.showsPausedBanner)
    }

    @MainActor
    @Test("re-arming programmatic ignore replaces instead of nesting")
    func programmaticIgnoreReplaces() async {
        let controller = ConversationAutoScrollController()
        controller.beginProgrammaticScroll()
        controller.beginProgrammaticScroll()
        #expect(controller.isIgnoringProgrammaticLiveScroll)
        #expect(!controller.notePossibleUserLiveScroll())

        try? await Task.sleep(for: .milliseconds(
            ConversationAutoScrollController.programmaticLiveScrollIgnoreMilliseconds + 40
        ))
        #expect(!controller.isIgnoringProgrammaticLiveScroll)
        #expect(controller.notePossibleUserLiveScroll())
        #expect(!controller.isFollowing)
    }

    @MainActor
    @Test("resume and session reset restore follow")
    func resumeAndReset() {
        let controller = ConversationAutoScrollController()
        _ = controller.noteDefiniteUserScroll()
        #expect(!controller.isFollowing)

        controller.resume()
        #expect(controller.isFollowing)

        _ = controller.noteDefiniteUserScroll()
        controller.beginProgrammaticScroll()
        controller.resetForNewSession()
        #expect(controller.isFollowing)
        #expect(!controller.isIgnoringProgrammaticLiveScroll)
    }
}
