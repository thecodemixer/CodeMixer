import SwiftUI

/// Progressive-disclosure modifier.
///
/// The container shows `content` only when the user signals intent: hover,
/// focus, an explicit summon (Cmd-K-style), or via `Voice Control`. Default
/// state is invisible — the UI stays serene; secondary actions surface on
/// demand.
///
/// Hover tracking covers both the host and the revealed control, with a short
/// dismiss grace so moving the pointer onto the reveal (e.g. a pin button)
/// does not hide it mid-flight.
public struct IntentReveal<Reveal: View>: ViewModifier {
    public enum Trigger: Sendable, Hashable { case hover, focus, sticky, alwaysOn }

    /// Matches visual-style §11 hover stability grace.
    private static var hoverDismissGraceNanoseconds: UInt64 { 50_000_000 }

    let trigger: Trigger
    let reveal: () -> Reveal

    @State private var contentHovering = false
    @State private var revealHovering = false
    @State private var showReveal = false
    @FocusState private var focused: Bool
    @State private var sticky = false
    @State private var dismissTask: Task<Void, Never>?

    public func body(content: Content) -> some View {
        content
            .onHover { updateContentHover($0) }
            .focused($focused)
            .overlay(alignment: .topTrailing) {
                if isVisible {
                    reveal()
                        .onHover { updateRevealHover($0) }
                        .transition(.opacity.combined(with: .scale(scale: 0.97, anchor: .topTrailing)))
                }
            }
            .animation(Theme.motion.quick, value: isVisible)
            .accessibilityAction(named: "Show actions") { sticky = true }
            .onDisappear {
                dismissTask?.cancel()
                dismissTask = nil
            }
    }

    private var isVisible: Bool {
        switch trigger {
        case .hover:    return showReveal
        case .focus:    return focused
        case .sticky:   return sticky || showReveal
        case .alwaysOn: return true
        }
    }

    private func updateContentHover(_ hovering: Bool) {
        contentHovering = hovering
        reconcileHover()
    }

    private func updateRevealHover(_ hovering: Bool) {
        revealHovering = hovering
        reconcileHover()
    }

    private func reconcileHover() {
        dismissTask?.cancel()
        dismissTask = nil
        if contentHovering || revealHovering {
            showReveal = true
            return
        }
        // Keep the reveal mounted briefly so the pointer can enter it.
        dismissTask = Task { @MainActor in
            try? await Task.sleep(nanoseconds: Self.hoverDismissGraceNanoseconds)
            guard !Task.isCancelled else { return }
            if !contentHovering && !revealHovering {
                showReveal = false
            }
        }
    }
}

public extension View {
    /// Reveal `content` according to a progressive-disclosure trigger.
    func revealOnIntent<Reveal: View>(_ trigger: IntentReveal<Reveal>.Trigger = .hover,
                                      @ViewBuilder _ content: @escaping () -> Reveal) -> some View {
        modifier(IntentReveal(trigger: trigger, reveal: content))
    }
}
