import SwiftUI
import AgentCore

// MARK: - Dropdown primitives

struct ComposerDropdownOption: Identifiable {
    let id: String
    let title: String
    let isSelected: Bool
    let action: () -> Void
}

/// A compact, menu-like list — not a card. Mirrors the density and row
/// chrome of a native `NSMenu` (tight rows, no dividers, hover/selection
/// wash, checkmark for the current value) while staying keyboard-navigable
/// like the slash palette (`SlashPaletteView`).
///
/// Presented as a plain overlay anchored to the trigger button — not
/// `.popover()` — because AppKit's `NSPopover` always paints a callout arrow
/// with no public API to suppress it (SwiftUI inherits that limitation on
/// macOS). A plain view sidesteps the arrow entirely and also avoids
/// `NSPopover`'s independent appearance/material resolution.
///
/// When `isSearchable` is true (model catalogs with dozens of entries), a
/// filter field sits above a scrollable list capped by `maxHeight`. Short
/// menus leave search off and grow to content within the same height cap.
struct ComposerDropdownPanel: View {
    let options: [ComposerDropdownOption]
    let onDismiss: () -> Void
    let minWidth: CGFloat
    let opaqueItemBackgrounds: Bool
    let isSearchable: Bool
    let maxHeight: CGFloat

    @Environment(\.codemixerDropdownCornerRadius) private var radius
    @State private var query: String = ""
    @State private var highlightedIndex: Int
    @FocusState private var isFocused: Bool

    init(
        options: [ComposerDropdownOption],
        minWidth: CGFloat = Theme.layout.compactControlMinWidth * 0.7,
        opaqueItemBackgrounds: Bool = false,
        isSearchable: Bool = false,
        maxHeight: CGFloat = Theme.layout.composerModelPickerMaxHeight,
        onDismiss: @escaping () -> Void
    ) {
        self.options = options
        self.minWidth = minWidth
        self.opaqueItemBackgrounds = opaqueItemBackgrounds
        self.isSearchable = isSearchable
        self.maxHeight = maxHeight
        self.onDismiss = onDismiss
        _highlightedIndex = State(initialValue: options.firstIndex { $0.isSelected } ?? 0)
    }

    private var filtered: [ComposerDropdownOption] {
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return options }
        return options.filter { $0.title.localizedCaseInsensitiveContains(trimmed) }
    }

    var body: some View {
        panelChrome
            .onAppear {
                clampHighlight()
                focusPanel()
            }
            .onChange(of: query) { _, _ in
                highlightedIndex = 0
            }
            .onChange(of: filtered.count) { _, _ in
                clampHighlight()
            }
    }

    @ViewBuilder
    private var panelChrome: some View {
        let chrome = VStack(alignment: .leading, spacing: 0) {
            if isSearchable {
                searchField
                Divider().overlay(Theme.surface.divider)
            }
            optionsList
        }
        .frame(minWidth: minWidth)
        .background(
            RoundedRectangle(cornerRadius: radius, style: .continuous)
                .fill(Theme.surface.card)
        )
        .overlay(
            RoundedRectangle(cornerRadius: radius, style: .continuous)
                .stroke(Theme.surface.divider, lineWidth: Theme.stroke.hairline)
        )
        // Flattens the panel into one fully opaque layer before the shadow
        // is composited, so no ancestor blending (transitions, vibrancy)
        // can make the card fill read as translucent.
        .compositingGroup()
        .shadow(color: .black.opacity(Theme.opacity.muted), radius: 12, y: 4)

        if isSearchable {
            // Focus stays on the search field — do not attach `.focused` here.
            chrome
        } else {
            chrome
                .focusable()
                .focusEffectDisabled()
                .focused($isFocused)
                .onKeyPress(.upArrow) { moveHighlight(-1) }
                .onKeyPress(.downArrow) { moveHighlight(1) }
                .onKeyPress(.return) { activateHighlighted() }
                .onKeyPress(.escape) {
                    onDismiss()
                    return .handled
                }
        }
    }

    private var searchField: some View {
        HStack(spacing: Theme.spacing.s8) {
            Image(systemName: "magnifyingglass")
                .accessibilityHidden(true)
                .foregroundStyle(Theme.text.tertiary)
                .font(Theme.typography.iconSmall)
            TextField("Search models…", text: $query)
                .textFieldStyle(.plain)
                .font(Theme.typography.label)
                .focused($isFocused)
                .onSubmit { _ = activateHighlighted() }
                .accessibilityLabel("Search models")
        }
        .padding(.horizontal, Theme.spacing.s8)
        .padding(.vertical, Theme.spacing.s8)
        // TextField steals focus, so arrows must be handled here (same
        // pattern as `CommandPaletteView`).
        .onKeyPress(.upArrow) { moveHighlight(-1) }
        .onKeyPress(.downArrow) { moveHighlight(1) }
        .onKeyPress(.escape) {
            onDismiss()
            return .handled
        }
    }

    private var optionsList: some View {
        // Overlay menus get an unbounded height proposal, so a bare
        // `ScrollView` + `maxHeight` collapses to zero. Searchable catalogs
        // (Cursor models) use a fixed-height scroller; short menus hug content.
        // No scroll-to-highlight: hover already updates the wash, and
        // auto-scrolling under the cursor is disorienting.
        Group {
            if isSearchable {
                ScrollView {
                    optionsStack
                }
                .scrollIndicators(.visible)
                .frame(height: maxHeight)
            } else {
                optionsStack
                    .frame(maxHeight: maxHeight)
            }
        }
    }

    private var optionsStack: some View {
        VStack(alignment: .leading, spacing: Theme.spacing.s4 / 2) {
            if filtered.isEmpty {
                Text(isSearchable ? "No matching models" : "No options")
                    .font(Theme.typography.caption)
                    .foregroundStyle(Theme.text.tertiary)
                    .padding(.horizontal, Theme.spacing.s8)
                    .padding(.vertical, Theme.spacing.s8)
                    .frame(maxWidth: .infinity, alignment: .leading)
            } else {
                ForEach(Array(filtered.enumerated()), id: \.element.id) { index, option in
                    row(option, isHighlighted: index == highlightedIndex)
                        // Hover only moves the active selection bar; only a
                        // click (`onTapGesture` below) confirms a choice.
                        .onHover { isHovering in
                            if isHovering { highlightedIndex = index }
                        }
                        .onTapGesture { activate(option) }
                }
            }
        }
        .padding(Theme.spacing.s4)
    }

    private func row(_ option: ComposerDropdownOption, isHighlighted: Bool) -> some View {
        HStack(spacing: Theme.spacing.s4) {
            Image(systemName: "checkmark")
                .accessibilityHidden(true)
                .font(Theme.typography.iconSmall)
                .opacity(option.isSelected ? 1 : 0)
                .frame(width: Theme.spacing.s12)
            Text(option.title)
                .font(Theme.typography.label)
            Spacer(minLength: Theme.spacing.s16)
        }
        .foregroundStyle(Theme.text.primary)
        .padding(.horizontal, Theme.spacing.s8)
        .padding(.vertical, Theme.spacing.s4)
        .frame(maxWidth: .infinity, alignment: .leading)
        .contentShape(Rectangle())
        .background(
            RoundedRectangle(cornerRadius: Theme.corner.chip, style: .continuous)
                .fill(rowBackground(isHighlighted: isHighlighted))
        )
        .accessibilityElement(children: .combine)
        .accessibilityLabel(option.title)
        .accessibilityAddTraits(option.isSelected ? [.isSelected, .isButton] : [.isButton])
    }

    private func rowBackground(isHighlighted: Bool) -> Color {
        if isHighlighted { return Theme.surface.bubbleUser }
        return opaqueItemBackgrounds ? Theme.surface.card : .clear
    }

    private func moveHighlight(_ delta: Int) -> KeyPress.Result {
        let items = filtered
        guard !items.isEmpty else { return .ignored }
        highlightedIndex = (highlightedIndex + delta + items.count) % items.count
        return .handled
    }

    private func activateHighlighted() -> KeyPress.Result {
        let items = filtered
        guard items.indices.contains(highlightedIndex) else { return .ignored }
        activate(items[highlightedIndex])
        return .handled
    }

    private func activate(_ option: ComposerDropdownOption) {
        option.action()
    }

    private func clampHighlight() {
        let count = filtered.count
        guard count > 0 else {
            highlightedIndex = 0
            return
        }
        if highlightedIndex >= count {
            highlightedIndex = count - 1
        }
    }

    /// Claims first responder after the overlay is in the hierarchy. A same-
    /// turn assign can lose to the trigger button still holding focus.
    private func focusPanel() {
        Task { @MainActor in
            isFocused = true
        }
    }
}

/// Positions `content` directly above its base view with `gap` of clear
/// space in between, regardless of `content`'s own height. The panel's
/// height varies with its option count, so it's measured live via
/// `GeometryReader` rather than assumed — then applied as a plain negative
/// vertical offset, which is unambiguous (up is negative `y`) unlike
/// `alignmentGuide` overrides, whose sign depends on which side's guide is
/// being redefined.
struct PositionedAboveAnchor: ViewModifier {
    @Binding var measuredHeight: CGFloat
    let gap: CGFloat

    func body(content: Content) -> some View {
        content
            .background(
                GeometryReader { proxy in
                    Color.clear
                        .onAppear { measuredHeight = proxy.size.height }
                        .onChange(of: proxy.size.height) { _, newValue in measuredHeight = newValue }
                }
            )
            .offset(y: -(measuredHeight + gap))
    }
}

extension View {
    func positionedAboveAnchor(height: Binding<CGFloat>, gap: CGFloat) -> some View {
        modifier(PositionedAboveAnchor(measuredHeight: height, gap: gap))
    }
}
