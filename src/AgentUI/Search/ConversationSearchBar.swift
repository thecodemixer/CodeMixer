import SwiftUI

/// Slide-down find bar (Cmd-F).
public struct ConversationSearchBar: View {
    @Binding public var query: String
    public let matchCount: Int
    public let currentIndex: Int
    public let onNext: () -> Void
    public let onPrev: () -> Void
    public let onDismiss: () -> Void

    public init(query: Binding<String>,
                matchCount: Int,
                currentIndex: Int,
                onNext: @escaping () -> Void,
                onPrev: @escaping () -> Void,
                onDismiss: @escaping () -> Void) {
        self._query = query
        self.matchCount = matchCount
        self.currentIndex = currentIndex
        self.onNext = onNext
        self.onPrev = onPrev
        self.onDismiss = onDismiss
    }

    public var body: some View {
        HStack(spacing: Theme.spacing.s8) {
            Image(systemName: "magnifyingglass").foregroundStyle(Theme.text.secondary)
                .accessibilityLabel("Search")
            TextField("Search in conversation", text: $query)
                .textFieldStyle(.plain)
                .font(Theme.typography.body)
                .onSubmit(onNext)
            if matchCount > 0 {
                Text("\(currentIndex + 1) / \(matchCount)")
                    .font(Theme.typography.caption)
                    .foregroundStyle(Theme.text.secondary)
                    .monospacedDigit()
            }
            Button(action: onPrev) { Image(systemName: "chevron.up") }
            .accessibilityLabel("Previous result")
                .buttonStyle(.bordered).controlSize(.small)
                .disabled(matchCount == 0)
                .keyboardShortcut(.upArrow, modifiers: [])
            Button(action: onNext) { Image(systemName: "chevron.down") }
            .accessibilityLabel("Next result")
                .buttonStyle(.bordered).controlSize(.small)
                .disabled(matchCount == 0)
                .keyboardShortcut(.downArrow, modifiers: [])
            Button(action: onDismiss) { Image(systemName: "xmark") }
            .accessibilityLabel("Close search")
                .buttonStyle(.borderless)
                .keyboardShortcut(.escape, modifiers: [])
        }
        .padding(.horizontal, Theme.spacing.s12)
        .padding(.vertical, Theme.spacing.s8)
        .background(Theme.surface.card)
        .overlay(alignment: .bottom) { Divider() }
        .accessibilityElement(children: .contain)
    }
}
