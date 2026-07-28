import SwiftUI
import AgentCore

/// The within-session index: "where am I / what has happened / what needs
/// me" without scrolling. Fixed-width, non-draggable leading lane.
///
/// Content-driven:
/// - Sessions with native `sessionPhaseChanged` (Custom ACP / migration tool)
///   are **phase-first**: the rail lists phases from `phaseMarkers` only.
///   Selecting a phase filters the transcript lane; turns do not nest here.
/// - Sessions without phase data fall back to a flat per-turn list.
/// - The rail itself is never shown in Focus mode (governed by the caller).
struct IndexRailView: View {
    @Bindable var model: EngineViewModel

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
            Divider().overlay(Theme.surface.divider)

            ScrollView {
                LazyVStack(alignment: .leading, spacing: 0) {
                    railRows
                }
                .padding(.vertical, Theme.spacing.s8)
            }

        }
        .frame(width: Theme.layout.indexRailWidth)
        .frame(maxHeight: .infinity, alignment: .topLeading)
        .background(Theme.surface.panel)
        .accessibilityElement(children: .contain)
    }

    @ViewBuilder
    private var railRows: some View {
        if model.hasPhaseData {
            let phases = model.railPhaseOccurrences
            ForEach(phases) { occurrence in
                phaseRow(occurrence)
            }
        } else {
            ForEach(model.conversationTurns) { turn in
                row(for: turn, indented: false)
            }
        }
    }

    // MARK: - Header

    private var header: some View {
        HStack(spacing: Theme.spacing.s8) {
            Text(model.hasPhaseData ? "Phases" : "Turns")
                .font(Theme.typography.label)
                .foregroundStyle(Theme.text.secondary)
            Spacer(minLength: 0)
            if showsJumpToLive {
                Button("Jump to live") { model.jumpToLiveTurn() }
                    .buttonStyle(.plain)
                    .font(Theme.typography.caption)
                    .foregroundStyle(Theme.signal.info)
                    .accessibilityLabel("Jump to the live turn")
            }
        }
        .padding(.leading, Theme.spacing.s24)
        .padding(.trailing, Theme.spacing.s12)
        .padding(.vertical, Theme.spacing.s8)
    }

    private var showsJumpToLive: Bool {
        if model.hasPhaseData {
            return !model.isFollowingLivePhase || !model.isFollowingLiveTurn
        }
        return !model.isFollowingLiveTurn
    }

    // MARK: - Phase row (native markers)

    private func phaseRow(_ occurrence: EngineViewModel.RailPhaseOccurrence) -> some View {
        let phase = occurrence.phase
        let round = occurrence.round
        let needsAttention = model.phaseGroupNeedsAttention(phase.group)
        let isExpanded = model.effectiveSelectedPhaseID == occurrence.id
        let isLive = occurrence.isLive
        return Button {
            model.selectPhase(occurrence.id)
        } label: {
            HStack(spacing: Theme.spacing.s8) {
                Circle()
                    .fill(needsAttention
                          ? Theme.signal.warning
                          : (isLive ? Theme.signal.info : Theme.text.tertiary))
                    .frame(width: Theme.layout.activityDotSize, height: Theme.layout.activityDotSize)
                    .accessibilityHidden(true)
                Text(phase.label)
                    .font(Theme.typography.label)
                    .foregroundStyle(Theme.text.primary)
                if round > 1 {
                    Text("Round \(round)")
                        .font(Theme.typography.caption)
                        .foregroundStyle(Theme.text.tertiary)
                }
                Spacer(minLength: 0)
                if let eta = model.currentPhaseETA, isLive {
                    Text(etaLabel(eta))
                        .font(Theme.typography.caption)
                        .foregroundStyle(Theme.text.tertiary)
                        .monospacedDigit()
                }
            }
            .padding(.leading, Theme.spacing.s24)
            .padding(.trailing, Theme.spacing.s12)
            .padding(.top, Theme.spacing.s12)
            .padding(.bottom, Theme.spacing.s4)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(isExpanded ? Theme.surface.bubbleUser.opacity(Theme.opacity.quiet) : Color.clear,
                        in: RoundedRectangle(cornerRadius: Theme.corner.small, style: .continuous))
        }
        .buttonStyle(.plain)
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(phase.label)\(round > 1 ? ", round \(round)" : "")\(needsAttention ? ", needs review" : "")\(isLive ? ", current" : "")\(isExpanded ? ", selected" : "")")
    }

    // MARK: - Turn row
    @ViewBuilder
    private func row(for turn: EngineViewModel.ConversationTurn, indented: Bool) -> some View {
        let isSelected = model.selectedTurnID == turn.id
            || (model.selectedTurnID == nil && model.effectiveSelectedTurn?.id == turn.id)
        Button {
            model.selectTurn(turn.id)
        } label: {
            HStack(alignment: .top, spacing: Theme.spacing.s8) {
                statusDot(for: turn.status)
                    .padding(.top, 3)

                VStack(alignment: .leading, spacing: Theme.spacing.s4) {
                    Text(turn.promptText ?? "…")
                        .font(Theme.typography.label)
                        .foregroundStyle(Theme.text.primary)
                        .lineLimit(1)

                    if turn.status == .running, let preview = turn.thinkingPreview {
                        Text(preview)
                            .font(Theme.typography.caption)
                            .foregroundStyle(Theme.text.tertiary)
                            .lineLimit(1)
                    }
                }

                Spacer(minLength: 0)

                if turn.toolCount > 0 {
                    Text("\(turn.toolCount)")
                        .font(Theme.typography.caption)
                        .monospacedDigit()
                        .foregroundStyle(Theme.text.tertiary)
                        .accessibilityLabel("\(turn.toolCount) tool calls")
                }
            }
            .padding(.leading, indented ? Theme.spacing.s32 : Theme.spacing.s24)
            .padding(.trailing, Theme.spacing.s12)
            .padding(.vertical, Theme.spacing.s8)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(isSelected ? Theme.surface.bubbleUser.opacity(Theme.opacity.quiet) : Color.clear,
                        in: RoundedRectangle(cornerRadius: Theme.corner.small, style: .continuous))
        }
        .buttonStyle(.plain)
        .contextMenu {
            Button("Copy prompt") {
                if let text = turn.promptText { DesktopActions.copyToPasteboard(text) }
            }
        }
        .accessibilityLabel(rowAccessibilityLabel(for: turn))
    }

    private func statusDot(for status: EngineViewModel.ConversationTurn.Status) -> some View {
        Circle()
            .fill(color(for: status))
            .frame(width: Theme.layout.activityDotSize, height: Theme.layout.activityDotSize)
            .accessibilityHidden(true)
    }

    private func color(for status: EngineViewModel.ConversationTurn.Status) -> Color {
        switch status {
        case .running: return Theme.signal.info
        case .done:    return Theme.text.tertiary
        case .failed:  return Theme.signal.danger
        }
    }

    private func rowAccessibilityLabel(for turn: EngineViewModel.ConversationTurn) -> String {
        var parts = ["Turn \(turn.ordinal + 1)", turn.promptText ?? "no prompt"]
        switch turn.status {
        case .running: parts.append("running")
        case .done: parts.append("done")
        case .failed: parts.append("failed")
        }
        if turn.toolCount > 0 { parts.append("\(turn.toolCount) tool calls") }
        return parts.joined(separator: ", ")
    }

    private func etaLabel(_ seconds: TimeInterval) -> String {
        let minutes = Int(seconds / 60)
        return minutes >= 1 ? "~\(minutes)m left" : "~\(Int(seconds))s left"
    }
}

#if DEBUG
#Preview("Index Rail – turns") {
    IndexRailView(model: .previewConversation)
        .frame(height: 480)
}

#Preview("Index Rail – phases, Light") {
    IndexRailView(model: .previewCustomACPPhases)
        .frame(height: 480)
        .preferredColorScheme(.light)
}

#Preview("Index Rail – phases, Dark") {
    IndexRailView(model: .previewCustomACPPhases)
        .frame(height: 480)
        .preferredColorScheme(.dark)
}

#Preview("Index Rail – Compact density") {
    IndexRailView(model: .previewCustomACPPhases)
        .frame(height: 480)
        .codemixerAppearance(AppearancePrefs(densityMode: .compact))
}
#endif
