import SwiftUI

/// Read-only viewer of the headless terminal screen. Useful when diagnosing
/// adapter-vs-binary protocol drift — the user can see what Codemixer's
/// SwiftTerm-backed emulator currently sees from the agent's TUI.
public struct DebugTerminalSheet: View {
    private static let refreshInterval: Duration = .milliseconds(500)

    public let snapshotText: (@Sendable () async -> String)?
    public let onClose: () -> Void

    @State private var text: String = ""

    public init(snapshotText: (@Sendable () async -> String)? = nil,
                onClose: @escaping () -> Void) {
        self.snapshotText = snapshotText
        self.onClose = onClose
    }

    public var body: some View {
        Group {
            if snapshotText == nil {
                EmptyState(system: "terminal",
                           title: "No local terminal",
                           subtitle: "Daemon-backed sessions do not expose terminal snapshots on the wire yet.")
            } else if text.isEmpty {
                EmptyState(system: "terminal",
                           title: "Terminal is empty",
                           subtitle: "Open a project or wait for the agent TUI to draw.")
            } else {
                ScrollView([.vertical, .horizontal]) {
                    Text(text)
                        .font(Theme.typography.monoSmall)
                        .fontDesign(.monospaced)
                        .foregroundStyle(Theme.text.primary)
                        .textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .topLeading)
                        .padding(Theme.spacing.s16)
                }
                .background(Theme.surface.card)
            }
        }
        .frame(minWidth: Theme.layout.debugTerminalMinWidth,
               minHeight: Theme.layout.debugTerminalMinHeight)
        .background(Theme.surface.canvas)
        .toolbar {
            ToolbarItem(placement: .cancellationAction) {
                Button("Done", action: onClose)
                    .keyboardShortcut(.cancelAction)
                    .accessibilityLabel("Close debug terminal")
            }
        }
        .movablePanelTitle("Debug Terminal")
        .task { await refreshLoop() }
    }

    private func refreshLoop() async {
        guard let snapshotText else { return }
        while !Task.isCancelled {
            text = await snapshotText()
            try? await Task.sleep(for: Self.refreshInterval)
        }
    }
}
