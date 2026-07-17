import SwiftUI
import AppKit
import AgentCore
import AgentProtocol

private enum WorkspaceFilePickerLimits {
    static let maxVisibleMatches = 100
}

// MARK: - Mode / model menus

struct ComposerModeModelMenus: View {
    @Bindable var model: EngineViewModel
    @Binding var selectedModelID: String

    @State private var showModeMenu = false
    @State private var showModelMenu = false
    @State private var modeMenuHeight: CGFloat = 0
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    /// Vertical gap between the dropdown panel and its trigger button.
    private static let dropdownGap: CGFloat = Theme.spacing.s4

    private var selectedModeLabel: String {
        model.availableAgentModes.first { $0.id == model.selectedAgentModeID }?.label
            ?? model.availableAgentModes.first?.label
            ?? "Mode"
    }

    var body: some View {
        HStack(spacing: Theme.spacing.s24) {
            if !model.availableAgentModes.isEmpty {
                modeMenu
            }
            if !model.availableModels.isEmpty {
                ComposerModelMenu(
                    model: model,
                    selectedModelID: $selectedModelID,
                    isOpen: $showModelMenu,
                    closeOtherMenus: { showModeMenu = false }
                )
            }
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
        .accessibilityLabel("Mode \(selectedModeLabel)")
        .overlay(alignment: .top) {
            if showModeMenu {
                ComposerDropdownPanel(
                    options: model.availableAgentModes.map { option in
                        ComposerDropdownOption(
                            id: option.id,
                            title: option.label,
                            isSelected: option.id == model.selectedAgentModeID
                        ) {
                            model.selectedAgentModeID = option.id
                            for command in option.selectCommands {
                                model.send(command)
                            }
                            showModeMenu = false
                        }
                    },
                    onDismiss: { showModeMenu = false }
                )
                .positionedAboveAnchor(height: $modeMenuHeight, gap: Self.dropdownGap)
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
            Text(selectedModeLabel)
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
