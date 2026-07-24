import SwiftUI
import AgentCore

/// Workspace tab: per-adapter model catalog rows for the current workspace,
/// with a manual refresh action per row.
struct WorkspaceSettingsTab: View {
    @Bindable var model: EngineViewModel

    var body: some View {
        Form {
            Section("Models") {
                if model.workspaceRoot == nil {
                    Text("Open a workspace to manage cached model catalogs.")
                        .font(Theme.typography.caption)
                        .foregroundStyle(Theme.text.secondary)
                } else {
                    ForEach(model.workspaceModelCatalogRows) { row in
                        modelRow(row)
                    }
                }
            }
        }
        .formStyle(.grouped)
        .task {
            await model.reloadWorkspaceModelCatalogStatus()
        }
        .onChange(of: model.workspaceRoot?.path) { _, _ in
            Task { await model.reloadWorkspaceModelCatalogStatus() }
        }
    }

    @ViewBuilder
    private func modelRow(_ row: EngineViewModel.WorkspaceModelCatalogRow) -> some View {
        VStack(alignment: .leading, spacing: Theme.spacing.s8) {
            HStack {
                Text(row.displayName)
                    .font(Theme.typography.label)
                Spacer()
                Text(modelCountLabel(row))
                    .font(Theme.typography.caption)
                    .foregroundStyle(Theme.text.tertiary)
            }
            Text(kindDetail(row))
                .font(Theme.typography.caption)
                .foregroundStyle(Theme.text.secondary)
            if let refreshedAt = row.refreshedAt {
                Text("Last refreshed \(refreshedAt.formatted(date: .abbreviated, time: .shortened))")
                    .font(Theme.typography.caption)
                    .foregroundStyle(Theme.text.tertiary)
            } else {
                Text("Not refreshed yet for this workspace")
                    .font(Theme.typography.caption)
                    .foregroundStyle(Theme.text.tertiary)
            }
            Button(model.modelCatalogRefreshInFlight == row.agentID ? "Refreshing…" : "Refresh models") {
                Task { await model.refreshAdapterModels(for: row.agentID) }
            }
            .disabled(model.modelCatalogRefreshInFlight != nil)
            .accessibilityLabel("Refresh \(row.displayName) models")
        }
        .padding(.vertical, Theme.spacing.s4)
    }

    private func kindDetail(_ row: EngineViewModel.WorkspaceModelCatalogRow) -> String {
        switch row.refreshKind {
        case .automatic:
            return "Cached in this workspace; refreshed at most once a day"
        case .manual(let detail):
            return detail
        }
    }

    private func modelCountLabel(_ row: EngineViewModel.WorkspaceModelCatalogRow) -> String {
        switch row.modelCount {
        case 0: return "No models cached"
        case 1: return "1 model"
        default: return "\(row.modelCount) models"
        }
    }
}
