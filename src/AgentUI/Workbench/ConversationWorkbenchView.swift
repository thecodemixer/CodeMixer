import SwiftUI

/// The calm 3-lane chat workbench: index rail + transcript lane + work lane,
/// with the composer pinned across the transcript+work width. Replaces the
/// old single centered-column `ConversationView`.
///
/// Uses one transcript instance per render. The earlier `ViewThatFits`
/// implementation evaluated multiple candidate layouts, which multiplied
/// markdown/code parsing cost while tokens streamed into long transcripts.
/// Focus mode still collapses the rail/work lane; the work lane remains
/// content-driven and draggable when visible.
///
/// Important: do **not** nest `HSplitView` beside the index rail inside a
/// `NavigationSplitView` detail. AppKit's split view claims the full window
/// width and pushes the rail under the session sidebar. Transcript/work
/// resizing uses a constrained `HStack` + drag handle instead.
struct ConversationWorkbenchView: View {
    @Bindable var model: EngineViewModel
    var voice: VoiceInputService?
    var tts: TTSService?
    @Binding var diffPanelVisible: Bool
    @Binding var searchVisible: Bool

    /// Local, session-transient Focus/Zen toggle — the extreme end of the
    /// density presets (§1.15), but not persisted: it is a reading-mode
    /// flip, not a change to the user's app-wide density preference.
    @State private var isFocusMode = false
    @State private var railPopoverVisible = false
    @State private var selectedCodePreview: WorkbenchCodePreview?
    @State private var workLaneWidth = Theme.layout.workLaneIdealWidth
    @State private var workLaneDragOrigin: CGFloat?

    @Environment(\.codemixerAppearance) private var appearance
    @Environment(\.effectiveReduceMotion) private var reduceMotion

    private var effectiveDensity: Theme.DensityMode {
        isFocusMode ? .focus : appearance.densityMode
    }

    private var railFitsInline: Bool { Self.railFitsInline(density: effectiveDensity) }
    private var workLaneHasContent: Bool {
        WorkLaneView.hasContent(model: model, selectedCodePreview: selectedCodePreview)
    }
    private var workLaneRequested: Bool {
        Self.workLaneRequested(density: effectiveDensity,
                               diffPanelVisible: diffPanelVisible,
                               hasCodePreview: selectedCodePreview != nil,
                               hasWorkContent: workLaneHasContent)
    }

    /// Whether the index rail claims an inline slot at this density — pure so
    /// it is directly unit-testable without inspecting the rendered view.
    /// `.focus` is the one density that collapses it to the leading toggle.
    static func railFitsInline(density: Theme.DensityMode) -> Bool {
        density != .focus
    }

    /// Whether the work lane should claim a slot (inline or overlay) at this
    /// density, independent of whether it currently has content to show.
    /// `.focus` always suppresses it; otherwise it follows the existing
    /// `diffPanelVisible` binding (⌘D / auto-open on new tool/diff activity).
    static func workLaneRequested(density: Theme.DensityMode,
                                  diffPanelVisible: Bool,
                                  hasCodePreview: Bool = false,
                                  hasWorkContent: Bool = false) -> Bool {
        density != .focus && (diffPanelVisible || hasCodePreview || hasWorkContent)
    }

    private var clampedWorkLaneWidth: CGFloat {
        min(max(workLaneWidth, Theme.layout.workLaneMinWidth),
            Theme.layout.workLaneIdealWidth * 1.5)
    }

    var body: some View {
        HStack(alignment: .top, spacing: 0) {
            rail
            composerColumn {
                transcriptAndWorkLanes
            }
            .frame(minWidth: 0, maxWidth: .infinity, maxHeight: .infinity)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .overlay(alignment: .topLeading) {
            if !railFitsInline {
                railToggle
            }
        }
        .background(Theme.surface.canvas)
        .background {
            // Cmd+Shift+J: the reading-mode escape hatch (§1.15 .focus).
            Button("Toggle Focus Mode") {
                withAnimation(Theme.motion.resolve(Theme.motion.changing, reduceMotion: reduceMotion)) {
                    isFocusMode.toggle()
                }
            }
            .keyboardShortcut("j", modifiers: [.command, .shift])
            .hidden()
        }
        .onChange(of: model.sessionID) { _, _ in
            isFocusMode = false
            railPopoverVisible = false
            selectedCodePreview = nil
            workLaneWidth = Theme.layout.workLaneIdealWidth
            workLaneDragOrigin = nil
        }
        .onChange(of: model.effectiveSelectedPhaseID) { _, _ in
            // Phase changes swap the transcript/work slice; keep the preview
            // from a previous phase from sticking to the new tools section.
            selectedCodePreview = nil
        }
        .onChange(of: model.selectedTurnID) { _, _ in
            selectedCodePreview = nil
        }
        .onKeyPress(.escape) {
            guard selectedCodePreview != nil else { return .ignored }
            selectedCodePreview = nil
            return .handled
        }
    }

    // MARK: - Shared pieces

    @ViewBuilder
    private var rail: some View {
        if railFitsInline {
            IndexRailView(model: model)
                .frame(width: Theme.layout.indexRailWidth)
                .frame(maxHeight: .infinity, alignment: .topLeading)
                .layoutPriority(1)
            Divider().overlay(Theme.surface.divider)
                .frame(maxHeight: .infinity)
                .layoutPriority(1)
        }
    }

    @ViewBuilder
    private var transcriptAndWorkLanes: some View {
        if workLaneRequested, workLaneHasContent {
            // Constrained HStack split — never HSplitView. Nesting AppKit's
            // split view beside the rail inside NavigationSplitView detail
            // lets the work/transcript panes claim the full window and shove
            // the Turns rail under the session sidebar.
            //
            // Work lane keeps layout priority so transcript banners / the
            // peripheral progress hairline growing never steal its width and
            // clip it away. Transcript is allowed to shrink below its idle
            // min width when space is tight.
            HStack(spacing: 0) {
                transcript
                    .frame(minWidth: 0, maxWidth: .infinity)
                    .layoutPriority(0)
                workLaneResizeHandle
                    .layoutPriority(1)
                workLane
                    .frame(width: clampedWorkLaneWidth)
                    .frame(minWidth: Theme.layout.workLaneMinWidth)
                    .frame(maxHeight: .infinity)
                    .layoutPriority(1)
                    .clipped()
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else {
            transcript
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }

    private var workLaneResizeHandle: some View {
        Rectangle()
            .fill(Theme.surface.divider)
            .frame(width: Theme.stroke.hairline)
            .frame(maxHeight: .infinity)
            .padding(.horizontal, Theme.spacing.s4)
            .contentShape(Rectangle())
            .onHover { hovering in
                DesktopActions.setColumnResizeCursor(hovering)
            }
            .gesture(
                DragGesture(minimumDistance: 1)
                    .onChanged { value in
                        if workLaneDragOrigin == nil {
                            workLaneDragOrigin = clampedWorkLaneWidth
                        }
                        // Dragging the handle right shrinks the work lane.
                        let origin = workLaneDragOrigin ?? clampedWorkLaneWidth
                        workLaneWidth = origin - value.translation.width
                    }
                    .onEnded { _ in
                        workLaneWidth = clampedWorkLaneWidth
                        workLaneDragOrigin = nil
                    }
            )
            .accessibilityLabel("Resize work lane")
            .accessibilityAdjustableAction { direction in
                let step = Theme.spacing.s16
                switch direction {
                case .increment: workLaneWidth = clampedWorkLaneWidth + step
                case .decrement: workLaneWidth = clampedWorkLaneWidth - step
                @unknown default: break
                }
                workLaneWidth = clampedWorkLaneWidth
            }
            .help("Drag to resize the work lane")
    }

    private var railToggle: some View {
        Button {
            railPopoverVisible = true
        } label: {
            Image(systemName: "list.bullet.indent")
                .imageScale(.medium)
        }
        .buttonStyle(.borderless)
        .padding(Theme.spacing.s8)
        .help("Show turn index")
        .accessibilityLabel("Show turn index")
        .popover(isPresented: $railPopoverVisible, arrowEdge: .leading) {
            IndexRailView(model: model)
        }
    }

    private var transcript: some View {
        TranscriptLaneView(model: model,
                           tts: tts,
                           searchVisible: $searchVisible,
                           selectedCodePreview: $selectedCodePreview)
    }

    private var workLane: some View {
        WorkLaneView(model: model,
                     selectedCodePreview: $selectedCodePreview)
    }

    private func composerColumn<Lanes: View>(@ViewBuilder lanes: () -> Lanes) -> some View {
        VStack(spacing: 0) {
            lanes()
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            PromptComposerView(model: model, voice: voice)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

#if DEBUG
#Preview("Workbench – turns, wide") {
    ConversationWorkbenchView(model: .previewConversation,
                              diffPanelVisible: .constant(true),
                              searchVisible: .constant(false))
        .frame(width: 1200, height: 720)
}

#Preview("Workbench – phases, wide") {
    ConversationWorkbenchView(model: .previewCustomACPPhases,
                              diffPanelVisible: .constant(true),
                              searchVisible: .constant(false))
        .frame(width: 1200, height: 720)
}

#Preview("Workbench – narrow") {
    ConversationWorkbenchView(model: .previewConversation,
                              diffPanelVisible: .constant(true),
                              searchVisible: .constant(false))
        .frame(width: 620, height: 720)
}

#Preview("Workbench – Comfortable density") {
    ConversationWorkbenchView(model: .previewCustomACPPhases,
                              diffPanelVisible: .constant(true),
                              searchVisible: .constant(false))
        .frame(width: 1200, height: 720)
        .codemixerAppearance(AppearancePrefs(densityMode: .comfortable))
}

#Preview("Workbench – Compact density") {
    ConversationWorkbenchView(model: .previewCustomACPPhases,
                              diffPanelVisible: .constant(true),
                              searchVisible: .constant(false))
        .frame(width: 1200, height: 720)
        .codemixerAppearance(AppearancePrefs(densityMode: .compact))
}

#Preview("Workbench – Focus density (zen)") {
    ConversationWorkbenchView(model: .previewCustomACPPhases,
                              diffPanelVisible: .constant(true),
                              searchVisible: .constant(false))
        .frame(width: 1200, height: 720)
        .codemixerAppearance(AppearancePrefs(densityMode: .focus))
}
#endif
