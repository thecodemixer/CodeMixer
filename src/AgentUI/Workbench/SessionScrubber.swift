import SwiftUI
import AgentCore

/// Compact per-file-session mini-map: one segment per native phase occurrence,
/// scrubbable to jump the rail/transcript to that point. It stays a thin strip:
/// hover expansion made the rail noisier and added scroll churn.
///
/// Only rendered by `IndexRailView` when `model.hasPhaseData` — content-
/// driven, so a plain per-turn session never sees this.
struct SessionScrubber: View {
    @Bindable var model: EngineViewModel

    /// A single current-phase capsule reads as a solid blue bar under the
    /// Turns rail and duplicates the transcript's peripheral progress
    /// hairline. Only show once there are multiple phase segments to scrub.
    static func shouldShow(for model: EngineViewModel) -> Bool {
        segmentCount(for: model) >= 2
    }

    static func segmentCount(for model: EngineViewModel) -> Int {
        model.railPhaseOccurrences.count
    }

    var body: some View {
        let currentSegments = segments
        HStack(spacing: Theme.stroke.hairline) {
            ForEach(currentSegments.indices, id: \.self) { index in
                let segment = currentSegments[index]
                Button {
                    jump(to: segment)
                } label: {
                    Capsule(style: .continuous)
                        .fill(segment.phase.group == currentGroup
                              ? Theme.signal.info : Theme.surface.divider)
                        .frame(height: Theme.spacing.s4)
                }
                .buttonStyle(.plain)
                .frame(width: max(segment.weight * scrubberWidth, Theme.spacing.s4))
                .help(segment.phase.label)
                .accessibilityLabel("Jump to \(segment.phase.label)")
            }
        }
        .frame(height: Theme.spacing.s4)
        .accessibilityElement(children: .contain)
    }

    private struct Segment {
        let id: String
        let phase: SessionPhase
        let weight: Double
    }

    private let scrubberWidth: CGFloat = Theme.layout.indexRailWidth - Theme.spacing.s16

    private var segments: [Segment] {
        let occurrences = model.railPhaseOccurrences
        guard !occurrences.isEmpty else { return [] }
        let evenWeight = 1.0 / Double(occurrences.count)
        return occurrences.map { occurrence in
            Segment(id: occurrence.id, phase: occurrence.phase, weight: evenWeight)
        }
    }

    private var currentGroup: SessionPhase.Group? { model.phaseMarkers.last?.phase.group }

    /// Jump to a phase: pins it in the rail (or follows live) and scrolls the
    /// transcript to that phase's native marker anchor.
    private func jump(to segment: Segment) {
        model.selectPhase(segment.id)
    }
}

#if DEBUG
#Preview("Session scrubber – Light") {
    SessionScrubber(model: .previewCustomACPPhases)
        .padding()
        .frame(width: Theme.layout.indexRailWidth)
        .preferredColorScheme(.light)
}

#Preview("Session scrubber – Dark") {
    SessionScrubber(model: .previewCustomACPPhases)
        .padding()
        .frame(width: Theme.layout.indexRailWidth)
        .preferredColorScheme(.dark)
}

#Preview("Session scrubber – Compact density") {
    SessionScrubber(model: .previewCustomACPPhases)
        .padding()
        .frame(width: Theme.layout.indexRailWidth)
        .codemixerAppearance(AppearancePrefs(densityMode: .compact))
}
#endif
