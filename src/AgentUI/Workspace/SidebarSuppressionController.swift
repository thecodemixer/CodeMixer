import SwiftUI

/// Temporary sidebar hiding for focused detail surfaces (dual folder previews).
///
/// A focused surface may hide the navigator while it owns the window, but that
/// is *presentation*, not a preference: it must never reach `AppearancePrefs`.
/// The scene routes every observed visibility change through `reaction(to:)`,
/// which distinguishes the user's own toggle (persist) from our programmatic
/// one (ignore) and from a request for the sidebar while suppressed
/// (releaseFocus). Stashing the pre-suppression value here — rather than
/// inferring it on exit — is what makes an already-hidden sidebar stay hidden
/// afterwards.
struct SidebarSuppressionController: Equatable {
    /// What the scene should do about an observed `columnVisibility` change.
    enum Reaction: Equatable {
        /// User-driven: write through to appearance prefs.
        case persist(visible: Bool)
        /// Our own suppression transition: leave prefs alone.
        case ignore
        /// The sidebar was asked for while a focused surface had it hidden.
        /// Showing the navigator is also a request to leave that surface, and
        /// it is the only way out when Escape never reaches the focused view —
        /// so this releases suppression rather than snapping the sidebar shut.
        case releaseFocus
    }

    private(set) var stashedVisibility: NavigationSplitViewVisibility?

    var isSuppressing: Bool { stashedVisibility != nil }

    /// Starts suppression. Returns the visibility to adopt, or `nil` when the
    /// sidebar is already hidden and nothing needs to move.
    mutating func begin(from current: NavigationSplitViewVisibility) -> NavigationSplitViewVisibility? {
        guard stashedVisibility == nil else { return nil }
        stashedVisibility = current
        return current == .detailOnly ? nil : .detailOnly
    }

    /// Ends suppression, returning the exact visibility to restore.
    mutating func end() -> NavigationSplitViewVisibility? {
        guard let stashed = stashedVisibility else { return nil }
        stashedVisibility = nil
        return stashed
    }

    /// Drops suppression without restoring the stashed visibility — the sidebar
    /// is already on screen because the user just asked for it.
    mutating func release() {
        stashedVisibility = nil
    }

    func reaction(to visibility: NavigationSplitViewVisibility) -> Reaction {
        guard isSuppressing else { return .persist(visible: visibility != .detailOnly) }
        return visibility == .detailOnly ? .ignore : .releaseFocus
    }
}
