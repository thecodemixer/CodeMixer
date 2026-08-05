import SwiftUI
import AgentCore

/// Read-only mirror of New / Configure Project for an already-registered
/// project. Opened from the sidebar project context menu.
public struct ProjectInfoSheet: View {
    public let project: WorkspaceProjectsStore.ProjectRef
    public let onClose: () -> Void

    public init(project: WorkspaceProjectsStore.ProjectRef,
                onClose: @escaping () -> Void) {
        self.project = project
        self.onClose = onClose
    }

    private var info: ProjectInfoPresentation {
        ProjectInfoPresentation.make(from: project)
    }

    public var body: some View {
        VStack(alignment: .leading, spacing: Theme.spacing.s24) {
            VStack(alignment: .leading, spacing: Theme.spacing.s8) {
                Text("Project Info")
                    .font(Theme.typography.title)
                Text("Read-only view of the settings chosen when this project was created.")
                    .font(Theme.typography.caption)
                    .foregroundStyle(Theme.text.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            VStack(alignment: .leading, spacing: Theme.spacing.s16) {
                labeledValue("Project type", info.categoryLabel)
                ForEach(Array(info.detailRows.enumerated()), id: \.offset) { _, row in
                    labeledValue(row.label, row.value)
                }
            }

            VStack(alignment: .leading, spacing: Theme.spacing.s16) {
                labeledValue(
                    project.projectType.isFolderBacked ? "Display name" : "Project name",
                    info.projectName
                )
                labeledValue("Location", info.path)
            }

            if let preferFresh = info.preferFreshAgentProcess {
                DisclosureGroup("Advanced") {
                    labeledValue(
                        "Launch new agent instance",
                        preferFresh ? "On" : "Off"
                    )
                    .padding(.top, Theme.spacing.s8)
                }
            }

            HStack {
                Spacer()
                Button("Done", action: onClose)
                    .buttonStyle(.borderedProminent)
                    .keyboardShortcut(.defaultAction)
                    .accessibilityLabel("Close project info")
            }
        }
        .padding(Theme.spacing.s24)
        .frame(minWidth: Theme.layout.agentPickerMinWidth,
               maxWidth: Theme.layout.agentPickerMaxWidth)
        .fixedSize(horizontal: false, vertical: true)
        .background(Theme.surface.canvas)
    }

    private func labeledValue(_ title: String, _ value: String) -> some View {
        VStack(alignment: .leading, spacing: Theme.spacing.s4) {
            Text(title)
                .font(Theme.typography.caption)
                .foregroundStyle(Theme.text.secondary)
            Text(value.isEmpty ? "—" : value)
                .font(Theme.typography.body)
                .foregroundStyle(Theme.text.primary)
                .textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(title): \(value.isEmpty ? "empty" : value)")
    }
}
