import SwiftUI
import AppKit
import AgentProtocol

// MARK: - User bubble

/// Right-aligned bubble for the user's own prompt.
///
/// When `isLast` is true a pencil affordance and context menu offer Edit +
/// Copy. The pencil calls `onEdit(text)` which pre-fills the composer; the
/// engine's stale-edit guard validates the UUID.
struct UserBubbleView: View {
    let text: String
    var isLast: Bool = false
    var onEdit: ((String) -> Void)? = nil

    var body: some View {
        HStack(alignment: .top, spacing: Theme.spacing.s8) {
            Spacer(minLength: Theme.spacing.s48)

            if isLast, let onEdit {
                Button {
                    onEdit(text)
                } label: {
                    Image(systemName: "pencil.circle")
                        .foregroundStyle(Theme.text.tertiary)
                        .imageScale(.medium)
                }
                .buttonStyle(.plain)
                .help("Edit and resubmit")
                .accessibilityLabel("Edit this message")
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
    /// Kept on the API for callers, but intentionally not rendered in the live
    /// transcript because it churns during token streaming.
    var tokenRate: Double? = nil
    var codePresentation: MarkdownProseView.CodePresentation = .expanded
    var onCollapsedCodeSelected: ((String, String?) -> Void)? = nil

    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        VStack(alignment: .leading, spacing: Theme.spacing.s8) {
            HStack(alignment: .top) {
                assistantContent
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
                    // waiting dots; once prose is streaming we hold a thin caret
                    // so the turn reads as "actively writing" without extra row
                    // transitions during scroll.
                    if text.isEmpty {
                        ShimmerDots()
                    } else {
                        StreamingCaret(reduceMotion: reduceMotion)
                    }
                }
                .padding(.top, Theme.spacing.s4)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    @ViewBuilder
    private var assistantContent: some View {
        if isStreaming {
            StreamingAssistantContentView(text: text,
                                          codePresentation: codePresentation,
                                          onCollapsedCodeSelected: onCollapsedCodeSelected)
                .accessibilityLabel("Assistant is responding")
        } else {
            MarkdownProseView(text: text,
                              codePresentation: codePresentation,
                              onCollapsedCodeSelected: onCollapsedCodeSelected)
                .accessibilityLabel("Assistant: \(MarkdownProseView.plainText(text))")
        }
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

private struct StreamingAssistantContentView: View {
    let text: String
    var codePresentation: MarkdownProseView.CodePresentation
    var onCollapsedCodeSelected: ((String, String?) -> Void)?

    var body: some View {
        // Same markdown path as finalized bubbles. Streaming used to force
        // plain `Text`, which made implementer/fixer prose look unformatted
        // next to A2UI cards. `codePresentation` still collapses fenced blocks
        // into the work-lane chip when the transcript asks for it.
        MarkdownProseView(text: text,
                          codePresentation: codePresentation,
                          onCollapsedCodeSelected: onCollapsedCodeSelected)
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
        VStack(alignment: .leading, spacing: Theme.spacing.s8) {
            // Match ToolCallCardView: header HStack + contentShape + onTapGesture.
            // Plain Button hit-testing on macOS ignores Spacer/empty regions.
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
            .accessibilityLabel("\(expanded ? "Collapse" : "Expand") thinking trace, \(durationLabel)")
            .accessibilityAction {
                withAnimation(Theme.motion.resolve(Theme.motion.quick, reduceMotion: reduceMotion)) {
                    expanded.toggle()
                }
            }

            if expanded, !text.isEmpty {
                // Reasoning traces are markdown too — headings and lists read as
                // literal `##` / `-` when typeset as one mono string.
                MarkdownProseView(text: text, emphasis: .secondary)
                    .padding(.top, Theme.spacing.s8)
            }
        }
        .padding(.horizontal, Theme.spacing.s12)
        .padding(.vertical, Theme.spacing.s8)
        .background(Theme.surface.bubble,
                    in: RoundedRectangle(cornerRadius: Theme.corner.medium))
        .animation(Theme.motion.resolve(Theme.motion.considered, reduceMotion: reduceMotion),
                   value: isThinking)
        .animation(Theme.motion.resolve(Theme.motion.quick, reduceMotion: reduceMotion),
                   value: expanded)
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

// MARK: - Client action marker

/// Centered, chrome-free history marker for an agent-affecting client intent.
/// Live session + export only — not restored from agent JSONL on resume.
struct ClientActionRowView: View {
    let action: ClientAction

    var body: some View {
        HStack(spacing: Theme.spacing.s8) {
            Image(systemName: symbolName)
                .font(Theme.typography.iconSmall)
                .foregroundStyle(Theme.text.tertiary)
                .accessibilityHidden(true)
            Text(action.title)
                .font(Theme.typography.caption)
                .foregroundStyle(Theme.text.tertiary)
            if let detail = action.detail {
                Text(detail)
                    .font(Theme.typography.caption)
                    .foregroundStyle(Theme.text.secondary)
            }
        }
        .padding(.vertical, Theme.spacing.s4)
        .frame(maxWidth: .infinity, alignment: .center)
        .accessibilityElement(children: .combine)
        .accessibilityLabel(accessibilityText)
    }

    private var symbolName: String {
        switch action.kind {
        case .mode, .permissionMode:
            return "slider.horizontal.3"
        case .model:
            return "cpu"
        case .slashCommand:
            return "terminal"
        case .permissionResponse:
            return "shield.lefthalf.filled"
        case .sessionLifecycle:
            return "arrow.triangle.2.circlepath"
        }
    }

    private var accessibilityText: String {
        if let detail = action.detail {
            return "Action: \(action.title) \(detail)"
        }
        return "Action: \(action.title)"
    }
}

// MARK: - Helpers

private func copyToClipboard(_ text: String) {
    DesktopActions.copyToPasteboard(text)
}
