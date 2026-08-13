import SwiftUI
import AgentCore

/// Settings view for an already-registered project. Opened from the sidebar
/// project context menu. Most fields mirror New / Configure Project; the
/// working directory is editable and applies on the next agent start.
public struct ProjectInfoSheet: View {
    public let project: WorkspaceProjectsStore.ProjectRef
    public let onClose: () -> Void
    public var onSetWorkingDirectory: ((_ url: URL?) async -> String?)?

    @State private var workingDirectoryURL: URL?
    @State private var workingDirectoryError: String?
    @State private var isSavingWorkingDirectory = false

    public init(project: WorkspaceProjectsStore.ProjectRef,
                onClose: @escaping () -> Void,
                onSetWorkingDirectory: ((_ url: URL?) async -> String?)? = nil) {
        self.project = project
        self.onClose = onClose
        self.onSetWorkingDirectory = onSetWorkingDirectory
        _workingDirectoryURL = State(initialValue: project.workingDirectoryPath.map {
            URL(fileURLWithPath: $0, isDirectory: true)
        })
    }

    private var info: ProjectInfoPresentation {
        ProjectInfoPresentation.make(from: project)
    }

    private var canEditWorkingDirectory: Bool {
        project.projectType.isAgentBacked && onSetWorkingDirectory != nil
    }

    public var body: some View {
        VStack(alignment: .leading, spacing: Theme.spacing.s24) {
            VStack(alignment: .leading, spacing: Theme.spacing.s8) {
                Text("Project Info")
                    .font(Theme.typography.title)
                Text("Settings chosen when this project was created. Working directory can be changed here.")
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
                    project.projectType.isAgentBacked ? "Project name" : "Display name",
                    info.projectName
                )
                labeledValue("Location", info.path)
                if project.projectType.isAgentBacked {
                    workingDirectorySection
                }
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

    @ViewBuilder
    private var workingDirectorySection: some View {
        VStack(alignment: .leading, spacing: Theme.spacing.s8) {
            Text("Working directory")
                .font(Theme.typography.caption)
                .foregroundStyle(Theme.text.secondary)
            HStack(spacing: Theme.spacing.s8) {
                Text(workingDirectoryURL?.path ?? project.path)
                    .font(Theme.typography.body)
                    .foregroundStyle(Theme.text.primary)
                    .textSelection(.enabled)
                    .lineLimit(2)
                    .truncationMode(.middle)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .accessibilityLabel("Working directory path")
                if canEditWorkingDirectory {
                    Button("Choose Folder…") {
                        guard let url = DesktopActions.chooseDirectoryPanel(
                            prompt: "Choose Working Directory"
                        ) else { return }
                        Task { await saveWorkingDirectory(url) }
                    }
                    .disabled(isSavingWorkingDirectory)
                    .accessibilityLabel("Choose working directory")
                    if workingDirectoryURL != nil {
                        Button("Use project folder") {
                            Task { await saveWorkingDirectory(nil) }
                        }
                        .disabled(isSavingWorkingDirectory)
                        .accessibilityLabel("Use project folder as working directory")
                    }
                }
            }
            Text("Applies the next time this project’s agent starts (reopen project or New Chat).")
                .font(Theme.typography.caption)
                .foregroundStyle(Theme.text.tertiary)
                .fixedSize(horizontal: false, vertical: true)
            if let workingDirectoryError {
                Text(workingDirectoryError)
                    .font(Theme.typography.caption)
                    .foregroundStyle(Theme.signal.warning)
                    .fixedSize(horizontal: false, vertical: true)
                    .accessibilityLabel(workingDirectoryError)
            }
        }
    }

    private func saveWorkingDirectory(_ url: URL?) async {
        guard let onSetWorkingDirectory else { return }
        isSavingWorkingDirectory = true
        defer { isSavingWorkingDirectory = false }
        if let error = await onSetWorkingDirectory(url) {
            workingDirectoryError = error
            return
        }
        workingDirectoryError = nil
        workingDirectoryURL = url.flatMap { candidate in
            candidate.standardizedFileURL.path == project.path ? nil : candidate
        }
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
