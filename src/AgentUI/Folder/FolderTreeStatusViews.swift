import SwiftUI
import AgentCore

/// Scan-truncation notice for a single folder tree root.
struct FolderTreeTruncationBanner: View {
    var body: some View {
        Text("Showing the first \(FolderBrowserLimits.maxScanEntries) entries. Narrow the folder or refresh after cleanup.")
            .font(Theme.typography.caption)
            .foregroundStyle(Theme.signal.warning)
            .padding(.horizontal, Theme.spacing.s16)
            .padding(.vertical, Theme.spacing.s8)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Theme.surface.panel)
            .accessibilityLabel("Folder listing truncated")
    }
}

/// Failure notice with a single recovery action, used by folder tree surfaces.
struct FolderTreeRecoveryBanner: View {
    let title: String
    let detail: String
    let actionTitle: String
    let action: () -> Void

    var body: some View {
        HStack(alignment: .top, spacing: Theme.spacing.s12) {
            VStack(alignment: .leading, spacing: Theme.spacing.s4) {
                Text(title)
                    .font(Theme.typography.label)
                    .foregroundStyle(Theme.signal.danger)
                Text(detail)
                    .font(Theme.typography.caption)
                    .foregroundStyle(Theme.text.secondary)
                    .lineLimit(3)
            }
            Spacer(minLength: 0)
            Button(actionTitle, action: action)
                .accessibilityLabel(actionTitle)
        }
        .padding(Theme.spacing.s12)
        .background(Theme.surface.panel)
    }
}

/// Empty / no-match placeholder for one tree root, sized to sit inside a pane.
struct FolderTreeEmptyState: View {
    let title: String
    let systemImage: String
    let detail: String
    var actionTitle: String?
    var action: (() -> Void)?

    var body: some View {
        VStack(spacing: Theme.spacing.s16) {
            ContentUnavailableView(title, systemImage: systemImage, description: Text(detail))
            if let actionTitle, let action {
                Button(actionTitle, action: action)
                    .accessibilityLabel(actionTitle)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .accessibilityLabel(title)
    }
}
