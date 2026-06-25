import SwiftUI
import AppKit
import AgentCore
import AgentProtocol

private enum WorkspaceFilePickerLimits {
    static let maxVisibleMatches = 100
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

struct ComposerModeToggle: View {
    let label: String
    let system: String
    @Binding var isOn: Bool
    @Binding var otherIsOn: Bool
    @Bindable var model: EngineViewModel
    let command: (Bool) -> AgentCommand

    var body: some View {
        Button {
            isOn.toggle()
            if isOn { otherIsOn = false }
            model.send(command(isOn))
        } label: {
            Label(label, systemImage: system)
                .labelStyle(.iconOnly)
                .foregroundStyle(isOn ? Theme.signal.info : Theme.text.secondary)
        }
        .buttonStyle(.bordered)
        .help("\(label) mode")
        .accessibilityLabel("\(label) mode \(isOn ? "on" : "off")")
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

// MARK: - File listing (free function — not MainActor isolated)

/// Recursively lists files in `workspace`, skipping common noise directories.
/// Capped at 200 entries. FileManager is thread-safe for read-only enumeration.
func listWorkspaceFiles(in workspace: URL) -> [String] {
    let skipDirs: Set<String> = [".git", "node_modules", ".build", "DerivedData",
                                 ".swiftpm", "__pycache__", ".DS_Store"]
    var results: [String] = []
    guard let enumerator = FileManager.default.enumerator(
        at: workspace,
        includingPropertiesForKeys: [.isRegularFileKey],
        options: [.skipsHiddenFiles]
    ) else { return [] }
    for case let url as URL in enumerator {
        if results.count >= 200 { break }
        if skipDirs.contains(url.lastPathComponent) {
            enumerator.skipDescendants()
            continue
        }
        if (try? url.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile) == true {
            let rel = url.path.replacingOccurrences(of: workspace.path + "/", with: "")
            results.append(rel)
        }
    }
    return results.sorted()
}

// MARK: - Regex helpers (Swift 5.7+ Regex literals)

extension String {
    func lastMatch(of regex: Regex<(Substring, Substring)>) -> (Substring, Substring)? {
        try? regex.firstMatch(in: self).map { ($0.output.0, $0.output.1) }
    }
}
