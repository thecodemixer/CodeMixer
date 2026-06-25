import SwiftUI

/// Progressive-disclosure modifier.
///
/// The container shows `content` only when the user signals intent: hover,
/// focus, an explicit summon (Cmd-K-style), or via `Voice Control`. Default
/// state is invisible — the UI stays serene; secondary actions surface on
/// demand.
public struct IntentReveal<Reveal: View>: ViewModifier {
    public enum Trigger: Sendable, Hashable { case hover, focus, sticky, alwaysOn }

    let trigger: Trigger
    let reveal: () -> Reveal

    @State private var hovering = false
    @FocusState private var focused: Bool
    @State private var sticky = false

    public func body(content: Content) -> some View {
        content
            .onHover { hovering = $0 }
            .focused($focused)
            .overlay(alignment: .topTrailing) {
                if isVisible {
                    reveal()
                        .transition(.opacity.combined(with: .scale(scale: 0.97, anchor: .topTrailing)))
                }
            }
            .animation(Theme.motion.quick, value: isVisible)
            .accessibilityAction(named: "Show actions") { sticky = true }
    }

    private var isVisible: Bool {
        switch trigger {
        case .hover:    return hovering
        case .focus:    return focused
        case .sticky:   return sticky || hovering
        case .alwaysOn: return true
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
