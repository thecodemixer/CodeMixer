import SwiftUI

struct WorkbenchCodePreview: Equatable {
    let code: String
    let language: String?

    var title: String {
        if let language, !language.isEmpty {
            return "\(language) code"
        }
        return "Code preview"
    }
}

/// Tools + changes, beside the reading column. Two stacked, content-driven
/// sections — present only when it has something to show.
///
/// Top: `ToolCallCardView`s for the effective phase (Custom ACP) or the
/// selected/live turn (plain sessions). Bottom: the existing `DiffPanelView`,
/// embedded whole — diffs are workspace-wide, so they are never scoped to a
/// single phase/turn.
struct WorkLaneView: View {
    @Bindable var model: EngineViewModel
    @Binding var selectedCodePreview: WorkbenchCodePreview?

    /// Whether the lane has anything to show right now — the caller uses
    /// this to decide whether to give the lane a slot at all (content-driven
    /// lanes: no tools this turn and no changed files means no work lane).
    static func hasContent(model: EngineViewModel,
                           selectedCodePreview: WorkbenchCodePreview? = nil) -> Bool {
        selectedCodePreview != nil
            || !model.effectiveWorkToolCalls.isEmpty
            || !model.changedFiles.isEmpty
    }

    var body: some View {
        VStack(spacing: 0) {
            if let preview = selectedCodePreview {
                codePreviewSection(preview)
                if hasToolOrDiffContent {
                    Divider().overlay(Theme.surface.divider)
                }
            }
            let toolCalls = model.effectiveWorkToolCalls
            if !toolCalls.isEmpty {
                toolsSection(toolCalls)
                if !model.changedFiles.isEmpty {
                    Divider().overlay(Theme.surface.divider)
                }
            }
            if !model.changedFiles.isEmpty {
                DiffPanelView(model: model, workspace: model.workspace)
            }
        }
        .frame(minWidth: Theme.layout.workLaneMinWidth, idealWidth: Theme.layout.workLaneIdealWidth)
        .background(Theme.surface.canvas)
    }

    private var hasToolOrDiffContent: Bool {
        !model.effectiveWorkToolCalls.isEmpty || !model.changedFiles.isEmpty
    }

    private func codePreviewSection(_ preview: WorkbenchCodePreview) -> some View {
        VStack(alignment: .leading, spacing: Theme.spacing.s12) {
            HStack(spacing: Theme.spacing.s8) {
                Image(systemName: "chevron.left.forwardslash.chevron.right")
                    .foregroundStyle(Theme.signal.info)
                    .accessibilityHidden(true)
                Text(preview.title)
                    .font(Theme.typography.label)
                    .foregroundStyle(Theme.text.primary)
                Spacer(minLength: 0)
                Button {
                    selectedCodePreview = nil
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .imageScale(.small)
                }
                .buttonStyle(.plain)
                .foregroundStyle(Theme.text.tertiary)
                .help("Close code preview")
                .accessibilityLabel("Close code preview")
            }
            CodeBlockView(code: preview.code, language: preview.language)
        }
        .padding(Theme.spacing.s16)
        .frame(maxHeight: hasToolOrDiffContent ? Theme.layout.workLaneToolsSectionMaxHeight : .infinity)
        .accessibilityElement(children: .contain)
    }

    @ViewBuilder
    private func toolsSection(_ toolCalls: [EngineViewModel.ToolCallEntry]) -> some View {
        ScrollView {
            VStack(alignment: .leading, spacing: Theme.spacing.s8) {
                Text(toolsHeaderTitle)
                    .font(Theme.typography.label)
                    .foregroundStyle(Theme.text.secondary)
                    .padding(.top, Theme.spacing.s16)

                ForEach(toolCalls) { entry in
                    ToolCallCardView(entry: entry)
                }
            }
            .padding(.horizontal, Theme.spacing.s16)
            .padding(.bottom, Theme.spacing.s16)
        }
        .frame(maxHeight: model.changedFiles.isEmpty ? .infinity : Theme.layout.workLaneToolsSectionMaxHeight)
    }

    private var toolsHeaderTitle: String {
        if model.hasPhaseData,
           let id = model.effectiveSelectedPhaseID,
           let label = model.railPhaseOccurrence(for: id)?.phase.label {
            return "Tools · \(label)"
        }
        if let turn = model.effectiveSelectedTurn {
            return "Tools · Turn \(turn.ordinal + 1)"
        }
        return "Tools"
    }
}

#if DEBUG
#Preview("Work Lane – Light") {
    let model = EngineViewModel.previewConversation
    return WorkLaneView(model: model,
                        selectedCodePreview: .constant(nil))
        .frame(width: 380, height: 480)
        .preferredColorScheme(.light)
}

#Preview("Work Lane – Dark") {
    let model = EngineViewModel.previewConversation
    return WorkLaneView(model: model,
                        selectedCodePreview: .constant(nil))
        .frame(width: 380, height: 480)
        .preferredColorScheme(.dark)
}

#Preview("Work Lane – Compact density") {
    let model = EngineViewModel.previewConversation
    return WorkLaneView(model: model,
                        selectedCodePreview: .constant(nil))
        .frame(width: 380, height: 480)
        .codemixerAppearance(AppearancePrefs(densityMode: .compact))
}
#endif
