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
    @Binding var thinkOn: Bool
    @Binding var reviewOn: Bool
    @Binding var selectedModelID: String
    @Binding var modeMenuAnchor: NSView?
    @Binding var modelMenuAnchor: NSView?

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
        Button { showModeMenu() } label: {
            modeMenuLabel
                .background(ComposerMenuAnchorView { modeMenuAnchor = $0 })
        }
        .buttonStyle(.plain)
        .fixedSize()
        .accessibilityLabel("Mode \(thinkOn ? "Think" : (reviewOn ? "Review" : "Agent"))")
    }

    private var modelMenu: some View {
        Button { showModelMenu() } label: {
            modelMenuLabel
                .background(ComposerMenuAnchorView { modelMenuAnchor = $0 })
        }
        .buttonStyle(.plain)
        .fixedSize()
        .accessibilityLabel("Model \(selectedModelLabel)")
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
            RoundedRectangle(cornerRadius: Theme.corner.small)
                .fill(Theme.surface.card.opacity(Theme.opacity.emphasized))
                .overlay(
                    RoundedRectangle(cornerRadius: Theme.corner.small)
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

    private func showModeMenu() {
        DesktopMenuPresenter.popUp(items: [
            DesktopMenuItem(title: "Agent") {
                thinkOn = false
                reviewOn = false
                model.send(.toggleThinkMode(enabled: false))
                model.send(.toggleReviewMode(enabled: false))
            },
            DesktopMenuItem(title: "Think") {
                thinkOn = true
                reviewOn = false
                model.send(.toggleThinkMode(enabled: true))
            },
            DesktopMenuItem(title: "Review") {
                thinkOn = false
                reviewOn = true
                model.send(.toggleReviewMode(enabled: true))
            },
        ], from: modeMenuAnchor)
    }

    private func showModelMenu() {
        DesktopMenuPresenter.popUp(items: model.availableModels.map { option in
            DesktopMenuItem(title: option.label) {
                selectedModelID = option.id
                model.send(.selectModel(id: option.id))
            }
        }, from: modelMenuAnchor)
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
        .background(Theme.surface.card)
        .focusable()
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
        .background(Theme.surface.card)
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
