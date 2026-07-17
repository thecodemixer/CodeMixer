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
struct ComposerDropdownPanel: View {
    let options: [ComposerDropdownOption]
    let onDismiss: () -> Void
    let minWidth: CGFloat
    let opaqueItemBackgrounds: Bool

    @Environment(\.codemixerDropdownCornerRadius) private var radius
    @State private var highlightedIndex: Int
    @FocusState private var isFocused: Bool

    init(
        options: [ComposerDropdownOption],
        minWidth: CGFloat = Theme.layout.compactControlMinWidth * 0.7,
        opaqueItemBackgrounds: Bool = false,
        onDismiss: @escaping () -> Void
    ) {
        self.options = options
        self.minWidth = minWidth
        self.opaqueItemBackgrounds = opaqueItemBackgrounds
        self.onDismiss = onDismiss
        _highlightedIndex = State(initialValue: options.firstIndex { $0.isSelected } ?? 0)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: Theme.spacing.s4 / 2) {
            ForEach(Array(options.enumerated()), id: \.element.id) { index, option in
                row(option, isHighlighted: index == highlightedIndex)
                    // Hover only moves the active selection bar; only a
                    // click (`onTapGesture` below) confirms a choice.
                    .onHover { isHovering in
                        if isHovering { highlightedIndex = index }
                    }
                    .onTapGesture { activate(option) }
            }
        }
        .padding(Theme.spacing.s4)
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
        .focusable()
        .focusEffectDisabled()
        .focused($isFocused)
        .onKeyPress(.upArrow) {
            guard !options.isEmpty else { return .ignored }
            highlightedIndex = (highlightedIndex - 1 + options.count) % options.count
            return .handled
        }
        .onKeyPress(.downArrow) {
            guard !options.isEmpty else { return .ignored }
            highlightedIndex = (highlightedIndex + 1) % options.count
            return .handled
        }
        .onKeyPress(.return) {
            guard options.indices.contains(highlightedIndex) else { return .ignored }
            activate(options[highlightedIndex])
            return .handled
        }
        .onKeyPress(.escape) {
            onDismiss()
            return .handled
        }
        .onAppear { isFocused = true }
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
        if opaqueItemBackgrounds {
            return isHighlighted ? Theme.surface.sunken : Theme.surface.card
        }
        return isHighlighted ? Theme.surface.bubbleUser : .clear
    }

    private func activate(_ option: ComposerDropdownOption) {
        option.action()
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
