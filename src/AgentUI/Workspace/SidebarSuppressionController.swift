import SwiftUI

/// Temporary sidebar hiding for focused detail surfaces (dual folder previews).
///
/// A focused surface may hide the navigator while it owns the window, but that
/// is *presentation*, not a preference: it must never reach `AppearancePrefs`.
/// The scene routes every observed visibility change through `reaction(to:)`,
/// which distinguishes the user's own toggle (persist) from our programmatic
/// one (ignore) and from a native split-view control fighting suppression
/// (correct). Stashing the pre-suppression value here — rather than inferring
/// it on exit — is what makes an already-hidden sidebar stay hidden afterwards.
struct SidebarSuppressionController: Equatable {
    /// What the scene should do about an observed `columnVisibility` change.
    enum Reaction: Equatable {
        /// User-driven: write through to appearance prefs.
        case persist(visible: Bool)
        /// Our own suppression transition: leave prefs alone.
        case ignore
        /// A native control reopened the sidebar while suppressed; force it back.
        case correct(to: NavigationSplitViewVisibility)
    }

    private(set) var stashedVisibility: NavigationSplitViewVisibility?

    var isSuppressing: Bool { stashedVisibility != nil }

    /// Manual affordances (⌘\, command palette) are inert while suppressed so a
    /// mid-suppression toggle cannot desync the stashed value.
    var allowsManualToggle: Bool { !isSuppressing }

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

    func reaction(to visibility: NavigationSplitViewVisibility) -> Reaction {
        guard isSuppressing else { return .persist(visible: visibility != .detailOnly) }
        return visibility == .detailOnly ? .ignore : .correct(to: .detailOnly)
    }
}
