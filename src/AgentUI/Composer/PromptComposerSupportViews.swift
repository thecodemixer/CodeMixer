import SwiftUI
import AppKit
import AgentCore
import AgentProtocol

private enum WorkspaceFilePickerLimits {
    static let maxVisibleMatches = 100
}

// MARK: - Mode / model menus

private struct ComposerDropdownOption: Identifiable {
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
private struct ComposerDropdownPanel: View {
    let options: [ComposerDropdownOption]
    let onDismiss: () -> Void

    @Environment(\.codemixerDropdownCornerRadius) private var radius
    @State private var highlightedIndex: Int
    @FocusState private var isFocused: Bool

    init(options: [ComposerDropdownOption], onDismiss: @escaping () -> Void) {
        self.options = options
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
        .frame(minWidth: Theme.layout.compactControlMinWidth * 0.7)
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
                .fill(isHighlighted ? Theme.surface.bubbleUser : Color.clear)
        )
        .accessibilityElement(children: .combine)
        .accessibilityLabel(option.title)
        .accessibilityAddTraits(option.isSelected ? [.isSelected, .isButton] : [.isButton])
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
private struct PositionedAboveAnchor: ViewModifier {
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

private extension View {
    func positionedAboveAnchor(height: Binding<CGFloat>, gap: CGFloat) -> some View {
        modifier(PositionedAboveAnchor(measuredHeight: height, gap: gap))
    }
}

struct ComposerModeModelMenus: View {
    @Bindable var model: EngineViewModel
    @Binding var thinkOn: Bool
    @Binding var reviewOn: Bool
    @Binding var selectedModelID: String

    @State private var showModeMenu = false
    @State private var showModelMenu = false
    @State private var modeMenuHeight: CGFloat = 0
    @State private var modelMenuHeight: CGFloat = 0
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    /// Vertical gap between the dropdown panel and its trigger button.
    private static let dropdownGap: CGFloat = Theme.spacing.s4

    private var selectedModelLabel: String {
        model.availableModels.first { $0.id == selectedModelID }?.label
            ?? model.availableModels.first?.label
            ?? "Model"
    }

    var body: some View {
        HStack(spacing: Theme.spacing.s24) {
            modeMenu
            modelMenu
        }
    }

    private var modeMenu: some View {
        Button {
            toggle($showModeMenu, closing: $showModelMenu)
        } label: {
            modeMenuLabel
        }
        .buttonStyle(.plain)
        .fixedSize()
        .accessibilityLabel("Mode \(thinkOn ? "Think" : (reviewOn ? "Review" : "Agent"))")
        .overlay(alignment: .top) {
            if showModeMenu {
                ComposerDropdownPanel(
                    options: [
                        ComposerDropdownOption(id: "agent", title: "Agent",
                                              isSelected: !thinkOn && !reviewOn) {
                            thinkOn = false
                            reviewOn = false
                            model.send(.toggleThinkMode(enabled: false))
                            model.send(.toggleReviewMode(enabled: false))
                            showModeMenu = false
                        },
                        ComposerDropdownOption(id: "think", title: "Think",
                                              isSelected: thinkOn) {
                            thinkOn = true
                            reviewOn = false
                            model.send(.toggleThinkMode(enabled: true))
                            showModeMenu = false
                        },
                        ComposerDropdownOption(id: "review", title: "Review",
                                              isSelected: reviewOn) {
                            thinkOn = false
                            reviewOn = true
                            model.send(.toggleReviewMode(enabled: true))
                            showModeMenu = false
                        },
                    ],
                    onDismiss: { showModeMenu = false }
                )
                .positionedAboveAnchor(height: $modeMenuHeight, gap: Self.dropdownGap)
                .transition(.opacity)
                .zIndex(1)
            }
        }
    }

    private var modelMenu: some View {
        Button {
            toggle($showModelMenu, closing: $showModeMenu)
        } label: {
            modelMenuLabel
        }
        .buttonStyle(.plain)
        .fixedSize()
        .accessibilityLabel("Model \(selectedModelLabel)")
        .overlay(alignment: .top) {
            if showModelMenu {
                ComposerDropdownPanel(
                    options: model.availableModels.map { option in
                        ComposerDropdownOption(id: option.id, title: option.label,
                                              isSelected: option.id == selectedModelID) {
                            selectedModelID = option.id
                            model.send(.selectModel(id: option.id))
                            showModelMenu = false
                        }
                    },
                    onDismiss: { showModelMenu = false }
                )
                .positionedAboveAnchor(height: $modelMenuHeight, gap: Self.dropdownGap)
                .transition(.opacity)
                .zIndex(1)
            }
        }
    }

    /// Toggles `menu` open/closed, closing `other` first so only one
    /// composer-bar dropdown is ever open at a time.
    private func toggle(_ menu: Binding<Bool>, closing other: Binding<Bool>) {
        let animation = Theme.motion.resolve(Theme.motion.arriving, reduceMotion: reduceMotion)
        withAnimation(animation) {
            other.wrappedValue = false
            menu.wrappedValue.toggle()
        }
    }

    private var modeMenuLabel: some View {
        HStack(spacing: Theme.spacing.s4) {
            Image(systemName: "infinity")
                .accessibilityHidden(true)
            Text(thinkOn ? "Think" : (reviewOn ? "Review" : "Agent"))
            Image(systemName: "chevron.down")
                .accessibilityHidden(true)
                .font(Theme.typography.iconSmall)
                .foregroundStyle(Theme.text.tertiary.opacity(Theme.opacity.secondary))
        }
        .padding(.horizontal, Theme.spacing.s8)
        .padding(.top, Theme.spacing.s4)
        .padding(.bottom, CGFloat.zero)
        .background(
            RoundedRectangle(cornerRadius: Theme.corner.dropdown)
                .fill(Theme.surface.card.opacity(Theme.opacity.emphasized))
                .overlay(
                    RoundedRectangle(cornerRadius: Theme.corner.dropdown)
                        .stroke(Theme.surface.divider, lineWidth: Theme.stroke.hairline)
                )
        )
        .foregroundStyle(Theme.text.secondary)
    }

    private var modelMenuLabel: some View {
        HStack(spacing: Theme.spacing.s4) {
            Text(selectedModelLabel)
                .font(Theme.typography.label)
            Image(systemName: "chevron.down")
                .accessibilityHidden(true)
                .font(Theme.typography.iconSmall)
                .foregroundStyle(Theme.text.tertiary.opacity(Theme.opacity.secondary))
        }
        .padding(.top, Theme.spacing.s4)
        .padding(.bottom, CGFloat.zero)
        .padding(.horizontal, Theme.spacing.s4)
        .contentShape(Rectangle())
        .foregroundStyle(Theme.text.secondary)
    }
}

// MARK: - Slash palette

struct ComposerActionButton: View {
    let canCancel: Bool
    let isEditMode: Bool
    let isSendDisabled: Bool
    let submit: () -> Void
    let cancel: () -> Void

    var body: some View {
        if canCancel {
            HStack(spacing: Theme.spacing.s8) {
                Button(action: cancel) {
                    Image(systemName: "stop.circle.fill")
                        .font(Theme.typography.iconMedium)
                        .foregroundStyle(Theme.text.primary)
                }
                .buttonStyle(.plain)
                .keyboardShortcut("c", modifiers: .control)
                .help("Stop current turn")
                .accessibilityLabel("Stop current turn")

                Button(action: submit) {
                    Image(systemName: "arrow.up.circle.fill")
                        .font(Theme.typography.iconMedium)
                        .foregroundStyle(isSendDisabled ? Theme.text.tertiary : Theme.text.primary)
                }
                .buttonStyle(.plain)
                .keyboardShortcut(.return, modifiers: [.command])
                .help(isEditMode ? "Resubmit edited message" : "Send prompt")
                .accessibilityLabel(isEditMode ? "Resubmit edited message" : "Send prompt")
                .disabled(isSendDisabled)
            }
            .transition(.opacity)
        } else {
            Button(action: submit) {
                Image(systemName: "arrow.up.circle.fill")
                    .font(Theme.typography.iconMedium)
                    .foregroundStyle(isSendDisabled ? Theme.text.tertiary : Theme.text.primary)
            }
            .buttonStyle(.plain)
            .keyboardShortcut(.return, modifiers: [.command])
            .accessibilityLabel(isEditMode ? "Resubmit edited message" : "Send prompt")
            .disabled(isSendDisabled)
            .transition(.opacity)
        }
    }
}

struct ComposerMicButton: View {
    let voice: VoiceInputService?
    let toggle: () -> Void

    private var isListening: Bool { voice?.isListening == true }

    var body: some View {
        HStack(spacing: Theme.spacing.s4) {
            Button(action: toggle) {
                ZStack {
                    Image(systemName: isListening ? "mic.fill" : "mic")
                        .foregroundStyle(isListening ? Theme.signal.danger : Theme.text.secondary)
                        .accessibilityLabel(isListening ? "Stop voice dictation" : "Start voice dictation")
                    if isListening {
                        Circle()
                            .fill(Theme.signal.danger.opacity(Theme.opacity.muted))
                            .frame(width: 30, height: 30)
                            .scaleEffect(isListening ? 1.4 : 1.0)
                            .animation(
                                Theme.motion.pulse.repeatForever(autoreverses: true),
                                value: isListening
                            )
                    }
                }
            }
            .buttonStyle(.bordered)
            .help(isListening ? "Stop dictation" : "Dictate prompt")
            .accessibilityLabel(isListening ? "Stop voice dictation" : "Start voice dictation")
            .disabled(voice == nil)

            if isListening, let voice {
                WaveformCanvas(levels: voice.audioLevels)
                    .frame(width: 48, height: 20)
                    .transition(.opacity.combined(with: .scale(scale: 0.8)))
                    .animation(Theme.motion.quick, value: isListening)
            }
        }
    }
}

struct SlashPaletteView: View {
    let query: String
    let commands: [SlashCommand]
    let onSelect: (SlashCommand) -> Void

    @State private var selectedIndex: Int = 0
    @FocusState private var isFocused: Bool

    private var filtered: [SlashCommand] {
        let base = query.isEmpty ? commands : commands.filter {
            $0.name.localizedCaseInsensitiveContains(query) ||
            $0.summary.localizedCaseInsensitiveContains(query)
        }
        return Array(base.prefix(12))
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            if filtered.isEmpty {
                Text("No matching commands")
                    .font(Theme.typography.caption)
                    .foregroundStyle(Theme.text.tertiary)
                    .padding(Theme.spacing.s12)
            } else {
                LazyVStack(alignment: .leading, spacing: 0) {
                    ForEach(Array(filtered.enumerated()), id: \.element.id) { index, command in
                        let isSelected = index == selectedIndex
                        Button {
                            onSelect(command)
                        } label: {
                            HStack(spacing: Theme.spacing.s8) {
                                Text(command.name)
                                    .font(Theme.typography.monoSmall)
                                    .fontDesign(.monospaced)
                                    .foregroundStyle(Theme.text.primary)
                                Text(command.summary)
                                    .font(Theme.typography.caption)
                                    .foregroundStyle(Theme.text.tertiary)
                                    .lineLimit(1)
                                if command.isProjectDefined {
                                    Text("project")
                                        .font(Theme.typography.caption)
                                        .foregroundStyle(Theme.signal.info)
                                        .padding(.horizontal, Theme.spacing.s4)
                                        .background(Theme.signal.info.opacity(Theme.opacity.subtle), in: .capsule)
                                }
                                Spacer()
                            }
                            .padding(.horizontal, Theme.spacing.s12)
                            .padding(.vertical, Theme.spacing.s8)
                            .contentShape(Rectangle())
                            .background(isSelected
                                ? Theme.surface.bubbleUser
                                : Color.clear)
                        }
                        .buttonStyle(.plain)
                        .accessibilityLabel("\(command.name): \(command.summary)")
                        .accessibilityAddTraits(isSelected ? [.isSelected] : [])
                        if command.id != filtered.last?.id { Divider() }
                    }
                }
            }
        }
        .frame(minWidth: Theme.layout.attachmentPaletteMinWidth, maxWidth: Theme.layout.attachmentPaletteMaxWidth)
        .floatingPopoverChrome()
        .focusable()
        .focusEffectDisabled()
        .focused($isFocused)
        .onKeyPress(.upArrow) {
            guard !filtered.isEmpty else { return .ignored }
            selectedIndex = (selectedIndex - 1 + filtered.count) % filtered.count
            return .handled
        }
        .onKeyPress(.downArrow) {
            guard !filtered.isEmpty else { return .ignored }
            selectedIndex = (selectedIndex + 1) % filtered.count
            return .handled
        }
        .onKeyPress(.return) {
            guard filtered.indices.contains(selectedIndex) else { return .ignored }
            onSelect(filtered[selectedIndex])
            return .handled
        }
        .onAppear {
            selectedIndex = 0
            isFocused = true
        }
        .onChange(of: query) { _, _ in
            selectedIndex = 0
        }
    }
}

// MARK: - @file picker

struct FilePickerView: View {
    let query: String
    let files: [String]
    let onSelect: (String) -> Void

    private var filtered: [String] {
        guard !query.isEmpty else { return Array(files.prefix(WorkspaceFilePickerLimits.maxVisibleMatches)) }
        return files
            .filter { $0.localizedCaseInsensitiveContains(query) }
            .prefix(WorkspaceFilePickerLimits.maxVisibleMatches)
            .map { $0 }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            if filtered.isEmpty {
                Text("No matching files")
                    .font(Theme.typography.caption)
                    .foregroundStyle(Theme.text.tertiary)
                    .padding(Theme.spacing.s12)
            } else {
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 0) {
                        ForEach(filtered, id: \.self) { file in
                            Button {
                                onSelect(file)
                            } label: {
                                Text(file)
                                    .font(Theme.typography.monoSmall)
                                    .fontDesign(.monospaced)
                                    .foregroundStyle(Theme.text.primary)
                                    .lineLimit(1)
                                    .truncationMode(.middle)
                                    .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(.horizontal, Theme.spacing.s12)
                            .padding(.vertical, Theme.spacing.s4)
                            .contentShape(Rectangle())
                            }
                            .buttonStyle(.plain)
                            .accessibilityLabel("File \(file)")
                        }
                        if files.count > WorkspaceFilePickerLimits.maxVisibleMatches {
                            Text("Show more… (\(files.count - WorkspaceFilePickerLimits.maxVisibleMatches) hidden)")
                                .font(Theme.typography.caption)
                                .foregroundStyle(Theme.text.tertiary)
                                .padding(Theme.spacing.s12)
                        }
                    }
                }
                .frame(maxHeight: Theme.layout.slashPaletteMaxHeight)
            }
        }
        .frame(minWidth: Theme.layout.slashPaletteMinWidth, maxWidth: Theme.layout.commandPaletteMaxWidth)
        .floatingPopoverChrome()
    }
}

// MARK: - Waveform Canvas

/// Real-time audio waveform drawn with SwiftUI Canvas.
///
/// `levels` is an array of 0…1 Float values (RMS power, one per recent audio buffer).
/// Renders as a symmetric bar chart — bars grow from centre to mimic a classic
/// waveform visualiser.
struct WaveformCanvas: View {
    let levels: [Float]

    var body: some View {
        Canvas { ctx, size in
            guard !levels.isEmpty else { return }
            let barWidth = size.width / CGFloat(levels.count)
            let midY = size.height / 2
            for (idx, level) in levels.enumerated() {
                let x = CGFloat(idx) * barWidth + barWidth / 2
                let barHeight = max(2, CGFloat(level) * size.height)
                let rect = CGRect(x: x - 1,
                                  y: midY - barHeight / 2,
                                  width: 2,
                                  height: barHeight)
                ctx.fill(Path(roundedRect: rect, cornerRadius: Theme.corner.hairline),
                         with: .color(Theme.signal.danger.opacity(Theme.opacity.emphasized + Theme.opacity.waveformRange * Double(level))))
            }
        }
        .accessibilityLabel("Audio waveform")
    }
}
