import SwiftUI

/// Prominent thinking surface for the live/selected turn — the workbench's
/// scoped deviation from visual-style §13.3 ("collapsed by default, caption
/// weight, never competes"). History keeps the §13.3 treatment via
/// `ThinkingBlockView`; this view is reserved for the turn currently live or
/// pinned in the index rail, so exactly one thinking surface is ever
/// prominent at a time (one-accent rule).
///
/// Shares `ThinkingBlockView`'s token vocabulary (surface, corner, shimmer,
/// motion) so the two read as one family despite the layout difference: no
/// `DisclosureGroup` here — the body stays expanded and pinned above prose.
struct ThinkingFocusView: View {
    let text: String
    /// `nil` while still streaming; set once `.thinkingComplete` lands.
    let duration: Duration?

    @State private var expanded = true
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private var isThinking: Bool { duration == nil }

    var body: some View {
        VStack(alignment: .leading, spacing: Theme.spacing.s8) {
            // Match ToolCallCardView: header HStack + contentShape + onTapGesture.
            // Plain Button hit-testing on macOS ignores Spacer/empty regions.
            HStack(spacing: Theme.spacing.s8) {
                if isThinking {
                    ShimmerDots()
                } else {
                    Image(systemName: "brain")
                        .foregroundStyle(Theme.text.secondary)
                        .accessibilityHidden(true)
                }
                Text(headerLabel)
                    .font(Theme.typography.label)
                    .foregroundStyle(Theme.text.primary)
                Spacer(minLength: 0)
                Image(systemName: expanded ? "chevron.down" : "chevron.right")
                    .font(Theme.typography.iconSmall)
                    .foregroundStyle(Theme.text.tertiary)
                    .accessibilityHidden(true)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .contentShape(Rectangle())
            .onTapGesture {
                withAnimation(Theme.motion.resolve(Theme.motion.quick, reduceMotion: reduceMotion)) {
                    expanded.toggle()
                }
            }
            .accessibilityElement(children: .combine)
            .accessibilityAddTraits(.isButton)
            .accessibilityLabel("\(expanded ? "Collapse" : "Expand") live thinking, \(headerLabel)")
            .accessibilityAction {
                withAnimation(Theme.motion.resolve(Theme.motion.quick, reduceMotion: reduceMotion)) {
                    expanded.toggle()
                }
            }

            if expanded, !text.isEmpty {
                MarkdownProseView(text: text, emphasis: .secondary)
                    // While thinking, only the tail matters; a full trace would
                    // push the answer off screen on every token.
                    .frame(maxHeight: isThinking ? Theme.layout.liveThinkingMaxHeight : nil,
                           alignment: .top)
                    .clipped()
            }
        }
        .padding(.horizontal, Theme.spacing.s16)
        .padding(.vertical, Theme.spacing.s12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Theme.surface.bubble,
                    in: RoundedRectangle(cornerRadius: Theme.corner.medium, style: .continuous))
        .animation(Theme.motion.resolve(Theme.motion.considered, reduceMotion: reduceMotion),
                   value: isThinking)
        .animation(Theme.motion.resolve(Theme.motion.quick, reduceMotion: reduceMotion),
                   value: expanded)
        .accessibilityElement(children: .combine)
        .accessibilityLabel("Live thinking: \(headerLabel). \(text)")
    }

    private var headerLabel: String {
        guard let duration else { return "Thinking…" }
        let seconds = duration.components.seconds
        return seconds < 1 ? "Thought for <1s" : "Thought for \(seconds)s"
    }
}

#if DEBUG
#Preview("Thinking Focus – active") {
    ThinkingFocusView(text: "Scanning the sidebar module for the navigator entry point…", duration: nil)
        .padding()
        .frame(width: 420)
}

#Preview("Thinking Focus – settled") {
    ThinkingFocusView(text: "Found `SessionSidebarView`; it already renders projects. I'll add resumable sessions beneath each project row.",
                       duration: .seconds(4))
        .padding()
        .frame(width: 420)
}
#endif
