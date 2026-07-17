import SwiftUI
import AgentCore

/// Feature-flagged debug pane: live timeline of normalised `AgentEvent`s.
///
/// Not shown in production by default — opened from the toolbar's overflow
/// menu. Useful when developing new adapters or diagnosing hook drift.
public struct EventLogView: View {
    public let bus: MulticastEventBus

    @State private var lines: [Line] = []
    @State private var subscriptionTask: Task<Void, Never>?

    public init(bus: MulticastEventBus) { self.bus = bus }

    public var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Text("Event log").font(Theme.typography.title)
                Spacer()
                Button("Clear") { lines.removeAll() }
                    .buttonStyle(.bordered).controlSize(.small)
                    .accessibilityLabel("Clear event log")
            }
            .padding(Theme.spacing.s12)

            ScrollView {
                LazyVStack(alignment: .leading, spacing: 2) {
                    ForEach(lines) { line in
                        HStack(spacing: Theme.spacing.s8) {
                            Text(line.timestamp).font(Theme.typography.caption)
                                .foregroundStyle(Theme.text.tertiary)
                                .monospacedDigit()
                            Pill(label: line.kind, tint: line.tint)
                            Text(line.body).font(Theme.typography.monoSmall)
                                .fontDesign(.monospaced)
                                .textSelection(.enabled)
                                .lineLimit(2)
                        }
                        .padding(.horizontal, Theme.spacing.s12)
                    }
                }
                .padding(.vertical, Theme.spacing.s8)
            }
            .background(Theme.surface.canvas)
        }
        .frame(minWidth: Theme.layout.eventLogMinWidth, minHeight: Theme.layout.eventLogMinHeight)
        .onAppear { startTailing() }
        .onDisappear { subscriptionTask?.cancel() }
    }

    private func startTailing() {
        subscriptionTask = Task {
            let sub = await bus.subscribe()
            for await entry in sub.stream {
                await MainActor.run {
                    let line = Line(id: entry.id,
                                    ordinal: lines.count + 1,
                                    event: entry.event)
                    lines.append(line)
                    if lines.count > 500 { lines.removeFirst(lines.count - 500) }
                }
            }
        }
    }
}

private struct Line: Identifiable {
    let id: UUID
    let timestamp: String
    let kind: String
    let body: String
    let tint: Color

    init(id: UUID, ordinal: Int, event: AgentEvent) {
        self.id = id
        self.timestamp = "#\(String(format: "%04d", ordinal))"
        switch event {
        case .sessionStarted(let id, _, _):       (kind, body, tint) = ("session", id, Theme.signal.info)
        case .userTurn(_, let t):                 (kind, body, tint) = ("user", t, Theme.text.primary)
        case .textDelta(_, let d):                (kind, body, tint) = ("delta", d, Theme.text.secondary)
        case .assistantText(_, _, let t, _):      (kind, body, tint) = ("asst", t, Theme.text.primary)
        case .thinkingChunk(_, let d):            (kind, body, tint) = ("think", d, Theme.text.tertiary)
        case .thinkingComplete:                   (kind, body, tint) = ("think+", "", Theme.text.tertiary)
        case .toolStart(_, let n, let i, _):      (kind, body, tint) = ("tool↑", "\(n): \(i.summary)", Theme.signal.info)
        case .toolEnd(_, let s, _, _):            (kind, body, tint) = ("tool↓", s ? "ok" : "err", s ? Theme.signal.success : Theme.signal.danger)
        case .toolProgress(_, let p):             (kind, body, tint) = ("tool…", String(describing: p), Theme.text.tertiary)
        case .permissionRequest(let p):           (kind, body, tint) = ("perm?", p.toolName, Theme.signal.warning)
        case .permissionAlreadyResolved:          (kind, body, tint) = ("perm✓", "", Theme.signal.success)
        case .statusPhraseChanged(_, let p):      (kind, body, tint) = ("status", p, Theme.text.secondary)
        case .activityStateChanged(let s):        (kind, body, tint) = ("activity", String(describing: s), Theme.text.tertiary)
        case .noEventGap(_, let e):               (kind, body, tint) = ("gap", String(describing: e), Theme.signal.warning)
        case .authURL(let u):                     (kind, body, tint) = ("auth", u.absoluteString, Theme.signal.info)
        case .bell:                               (kind, body, tint) = ("bell", "", Theme.signal.warning)
        case .fileTouched(let u, _):              (kind, body, tint) = ("file", u.lastPathComponent, Theme.signal.info)
        case .usage(let t, let c):                (kind, body, tint) = ("usage", "\(t) tok cost=\(c.map(String.init(describing:)) ?? "?")", Theme.signal.info)
        case .engineRestarted:                    (kind, body, tint) = ("restart", "", Theme.signal.warning)
        case .stopped(let r):                     (kind, body, tint) = ("stop", String(describing: r), Theme.text.secondary)
        case .error(let e):                       (kind, body, tint) = ("error", String(describing: e), Theme.signal.danger)
        case .speakBubbleRequested(let id):       (kind, body, tint) = ("tts", id, Theme.text.tertiary)
        case .fileReverted(let p):                (kind, body, tint) = ("revert", p, Theme.signal.warning)
        case .prefsChanged(let n):                (kind, body, tint) = ("prefs", "rules=\(n)", Theme.text.tertiary)
        case .appearancePrefChanged(let k, let v): (kind, body, tint) = ("appearance", "\(k.rawValue)=\(v)", Theme.text.tertiary)
        case .snapshotReady(let k, let d):        (kind, body, tint) = ("snapshot", "\(k.rawValue) \(d.count)B", Theme.text.tertiary)
        case .clientAction(let action):
            let text = action.detail.map { "\(action.title): \($0)" } ?? action.title
            (kind, body, tint) = ("action", text, Theme.text.tertiary)
        }
    }
}

#if DEBUG
#Preview("Event log") {
    EventLogView(bus: MulticastEventBus())
        .preferredColorScheme(.light)
}
#endif
