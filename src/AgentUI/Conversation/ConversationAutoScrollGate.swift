import Foundation
import Observation

/// Explicit auto-follow controller for the conversation scroll surface.
///
/// Follow stays on until a definite user scroll arrives. Resume is deliberate
/// (banner button, session switch, or send).
///
/// Programmatic `scrollTo` briefly suppresses *live-scroll* notifications
/// (scrollbar/animation echoes). Wheel / trackpad / Page keys always win —
/// they must never wait for that window, or streaming follow would swallow
/// the first several gestures (nested ignore depth used to do exactly that).
@Observable
@MainActor
final class ConversationAutoScrollController {
    private(set) var isFollowing: Bool = true
    /// Suppresses only ambiguous live-scroll notifications from our own jumps.
    private(set) var isIgnoringProgrammaticLiveScroll: Bool = false
    private var programmaticIgnoreGeneration: Int = 0

    var showsPausedBanner: Bool { !isFollowing }

    /// Arms a short ignore window for live-scroll echoes. Re-arming replaces
    /// the previous window instead of nesting depth (streaming used to stack
    /// ignore depth so user scrolls were ignored until a quiet gap).
    func beginProgrammaticScroll() {
        programmaticIgnoreGeneration += 1
        let generation = programmaticIgnoreGeneration
        isIgnoringProgrammaticLiveScroll = true
        Task { @MainActor in
            try? await Task.sleep(for: .milliseconds(Self.programmaticLiveScrollIgnoreMilliseconds))
            guard generation == self.programmaticIgnoreGeneration else { return }
            self.isIgnoringProgrammaticLiveScroll = false
        }
    }

    /// Wheel / trackpad / Page keys — always pauses, cancels programmatic ignore.
    @discardableResult
    func noteDefiniteUserScroll() -> Bool {
        programmaticIgnoreGeneration += 1
        isIgnoringProgrammaticLiveScroll = false
        guard isFollowing else { return false }
        isFollowing = false
        return true
    }

    /// Scrollbar live-scroll — may be an echo of `scrollTo`; respect ignore.
    @discardableResult
    func notePossibleUserLiveScroll() -> Bool {
        guard isFollowing, !isIgnoringProgrammaticLiveScroll else { return false }
        isFollowing = false
        return true
    }

    func resume() {
        isFollowing = true
    }

    func resetForNewSession() {
        programmaticIgnoreGeneration += 1
        isIgnoringProgrammaticLiveScroll = false
        isFollowing = true
    }

    static let programmaticLiveScrollIgnoreMilliseconds: Int = 80
}

/// Pure helpers for unit tests.
enum ConversationAutoScrollGate {
    static func shouldAcceptLiveScroll(isFollowing: Bool,
                                       ignoringProgrammaticLiveScroll: Bool) -> Bool {
        isFollowing && !ignoringProgrammaticLiveScroll
    }

    static func definiteUserScrollAlwaysWins(isFollowing: Bool) -> Bool {
        isFollowing
    }
}
