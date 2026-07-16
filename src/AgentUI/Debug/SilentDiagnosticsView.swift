import SwiftUI
import AgentCore

/// Opt-in pane listing silent recovery records from `SilentDiagnostics.shared`.
public struct SilentDiagnosticsView: View {
    @State private var records: [SilentDiagnostics.Record] = []
    @State private var refreshTask: Task<Void, Never>?

    public init() {}

    public var body: some View {
        VStack(alignment: .leading, spacing: Theme.spacing.s12) {
            HStack {
                Text("Silent recovery log")
                    .font(Theme.typography.title)
                Spacer()
                Button("Clear") {
                    Task {
                        await SilentDiagnostics.shared.clear()
                        records = await SilentDiagnostics.shared.snapshot()
                    }
                }
                .accessibilityLabel("Clear silent recovery log")
            }

            if records.isEmpty {
                Text("No silent recoveries recorded.")
                    .font(Theme.typography.body)
                    .foregroundStyle(Theme.text.secondary)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: Theme.spacing.s8) {
                        ForEach(records) { record in
                            VStack(alignment: .leading, spacing: Theme.spacing.s4) {
                                HStack(spacing: Theme.spacing.s8) {
                                    Text(record.kind.rawValue)
                                        .font(Theme.typography.monoSmall)
                                        .foregroundStyle(Theme.signal.warning)
                                    Text(record.owner)
                                        .font(Theme.typography.caption)
                                        .foregroundStyle(Theme.text.tertiary)
                                    Spacer()
                                    Text(record.timestamp, style: .time)
                                        .font(Theme.typography.caption)
                                        .foregroundStyle(Theme.text.tertiary)
                                }
                                Text(record.summary)
                                    .font(Theme.typography.body)
                                if let details = record.details, !details.isEmpty {
                                    Text(details)
                                        .font(Theme.typography.caption)
                                        .foregroundStyle(Theme.text.secondary)
                                }
                            }
                            .padding(Theme.spacing.s8)
                            .background(Theme.surface.card)
                            .clipShape(RoundedRectangle(cornerRadius: Theme.corner.small))
                        }
                    }
                }
            }
        }
        .padding(Theme.spacing.s16)
        .frame(minWidth: Theme.layout.eventLogMinWidth,
               minHeight: Theme.layout.eventLogMinHeight)
        .background(Theme.surface.canvas)
        .onAppear { startPolling() }
        .onDisappear {
            refreshTask?.cancel()
            refreshTask = nil
        }
    }

    private func startPolling() {
        refreshTask?.cancel()
        refreshTask = Task {
            while !Task.isCancelled {
                records = await SilentDiagnostics.shared.snapshot()
                try? await Task.sleep(for: .seconds(1))
            }
        }
    }
}

#if DEBUG
#Preview("Silent diagnostics – Light") {
    SilentDiagnosticsView()
        .frame(width: 480, height: 320)
        .preferredColorScheme(.light)
}

#Preview("Silent diagnostics – Dark") {
    SilentDiagnosticsView()
        .frame(width: 480, height: 320)
        .preferredColorScheme(.dark)
}
#endif
