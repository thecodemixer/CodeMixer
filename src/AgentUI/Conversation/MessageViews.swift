import SwiftUI
import AppKit
import AgentProtocol

// MARK: - User bubble

/// Right-aligned bubble for the user's own prompt.
///
/// When `isLast` is true a pencil affordance appears on hover and a context
/// menu offers Edit + Copy. The pencil calls `onEdit(text)` which pre-fills
/// the composer; the engine's stale-edit guard validates the UUID.
struct UserBubbleView: View {
    let text: String
    var isLast: Bool = false
    var onEdit: ((String) -> Void)? = nil

    @State private var hovered = false

    var body: some View {
        HStack(alignment: .top, spacing: Theme.spacing.s8) {
            Spacer(minLength: Theme.spacing.s48)

            if isLast, let onEdit {
                Button {
                    onEdit(text)
                } label: {
                    Image(systemName: "pencil.circle")
                        .foregroundStyle(hovered ? Theme.signal.info : Theme.text.tertiary)
                        .imageScale(.medium)
                }
                .buttonStyle(.plain)
                .help("Edit and resubmit")
                .accessibilityLabel("Edit this message")
                .opacity(hovered ? 1 : 0)
                .animation(Theme.motion.quick, value: hovered)
            }

            Text(text)
                .font(Theme.typography.body)
                .foregroundStyle(Theme.text.primary)
                .padding(.horizontal, Theme.spacing.s16)
                .padding(.vertical, Theme.spacing.s12)
                .background(Theme.surface.bubbleUser,
                            in: RoundedRectangle(cornerRadius: Theme.corner.large, style: .continuous))
                .textSelection(.enabled)
                .accessibilityLabel("You said: \(text)")
                .contextMenu {
                    Button("Copy") { copyToClipboard(text) }
                    if isLast, let onEdit {
                        Divider()
                        Button("Edit and Resubmit") { onEdit(text) }
                    }
                }
        }
        .onHover { hovered = $0 }
    }
}

// MARK: - Assistant text

/// Flowing assistant prose — no bubble, just typography with optional TTS.
struct AssistantTextView: View {
    let text: String
    let isStreaming: Bool
    var bubbleID: UUID?
    var tts: TTSService? = nil
    var onTTSAction: ((UUID, TTSAction) -> Void)? = nil
    /// Rolling tok/s estimate forwarded from `EngineViewModel.tokenRatePerSecond`.
    /// Displayed in the streaming footer when non-nil.
    var tokenRate: Double? = nil

    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        VStack(alignment: .leading, spacing: Theme.spacing.s8) {
            HStack(alignment: .top) {
                MarkdownProseView(text: text)
                    .accessibilityLabel("Assistant: \(MarkdownProseView.plainText(text))")
                    .contextMenu {
                        Button("Copy") { copyToClipboard(text) }
                        if let tts {
                            Divider()
                            if isCurrentTTS(tts) {
                                Button("Stop Speaking") { sendTTS(.stop) }
                                Button("Pause") { sendTTS(.pause) }
                            } else {
                                Button("Speak") { sendTTS(.play) }
                            }
                        }
                    }

                if let tts, !isStreaming {
                    ttsButton(tts)
                        .padding(.leading, Theme.spacing.s8)
                }
            }

            if isStreaming {
                HStack(spacing: Theme.spacing.s8) {
                    // Streaming presence: while no tokens have arrived we show the
                    // waiting dots; once prose is streaming we cross-fade to a thin
                    // caret so the turn reads as "actively writing". One motion token,
                    // reduced-motion safe (caret holds steady).
                    if text.isEmpty {
                        ShimmerDots()
                            .transition(.opacity)
                    } else {
                        StreamingCaret(reduceMotion: reduceMotion)
                            .transition(.opacity)
                    }
                    if let rate = tokenRate {
                        Text(String(format: "%.0f tok/s", rate))
                            .font(Theme.typography.caption)
                            .foregroundStyle(Theme.text.tertiary)
                            .monospacedDigit()
                            .transition(.opacity)
                    }
                }
                .padding(.top, Theme.spacing.s4)
                .animation(Theme.motion.resolve(Theme.motion.changing, reduceMotion: reduceMotion),
                           value: text.isEmpty)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    @ViewBuilder
    private func ttsButton(_ tts: TTSService) -> some View {
        let isCurrent = isCurrentTTS(tts)
        Button {
            if isCurrent {
                sendTTS(.stop)
            } else {
                sendTTS(.play)
            }
        } label: {
            Image(systemName: isCurrent ? "stop.circle" : "speaker.wave.2")
                .foregroundStyle(isCurrent ? Theme.signal.danger : Theme.text.tertiary)
                .imageScale(.small)
        }
        .buttonStyle(.plain)
        .help(isCurrent ? "Stop speaking" : "Speak aloud")
        .accessibilityLabel(isCurrent ? "Stop speaking" : "Read aloud")
    }

    private func isCurrentTTS(_ tts: TTSService) -> Bool {
        guard let bubbleID else { return false }
        return tts.isSpeaking && (tts.currentBubbleID?.contains(bubbleID.uuidString) ?? false)
    }

    private func sendTTS(_ action: TTSAction) {
        guard let bubbleID else { return }
        onTTSAction?(bubbleID, action)
    }
}

// MARK: - Thinking block

/// Collapsible inline card for a chain-of-thought block.
///
/// While a turn is in progress, shows the accumulating text as it arrives.
/// After `.thinkingComplete`, shows duration and keeps the text on expand.
struct ThinkingBlockView: View {
    let text: String
    let duration: Duration?
    let isCurrent: Bool

    @State private var expanded = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private var isThinking: Bool { duration == nil }

    var body: some View {
        DisclosureGroup(isExpanded: $expanded) {
            if !text.isEmpty {
                Text(text)
                    .font(Theme.typography.monoSmall)
                    .fontDesign(.monospaced)
                    .foregroundStyle(Theme.text.secondary)
                    .padding(.top, Theme.spacing.s8)
                    .textSelection(.enabled)
            }
        } label: {
            HStack(spacing: Theme.spacing.s8) {
                if isThinking {
                    // Still accumulating — show shimmer alongside label.
                    ShimmerDots()
                } else {
                    Image(systemName: "brain")
                        .accessibilityLabel("Thinking")
                        .foregroundStyle(Theme.text.tertiary)
                }
                Text(durationLabel)
                    .font(Theme.typography.caption)
                    .foregroundStyle(Theme.text.tertiary)
            }
        }
        .padding(.horizontal, Theme.spacing.s12)
        .padding(.vertical, Theme.spacing.s8)
        .background(Theme.surface.bubble,
                    in: RoundedRectangle(cornerRadius: Theme.corner.medium))
        .animation(Theme.motion.resolve(Theme.motion.considered, reduceMotion: reduceMotion),
                   value: isThinking)
        .accessibilityLabel("Thinking trace: \(durationLabel)")
        // Keep the latest thought open so the current reasoning remains visible;
        // older completed thoughts collapse into compact "Thought for Xs" rows.
        .onAppear { expanded = isCurrent || isThinking }
        .onChange(of: isThinking) { _, stillThinking in expanded = isCurrent || stillThinking }
        .onChange(of: isCurrent) { _, current in expanded = current || isThinking }
    }

    private var durationLabel: String {
        guard let duration else { return "Thinking…" }
        let seconds = duration.components.seconds
        return seconds < 1 ? "Thought for <1s" : "Thought for \(seconds)s"
    }
}

// MARK: - Helpers

private func copyToClipboard(_ text: String) {
    DesktopActions.copyToPasteboard(text)
}
