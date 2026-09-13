import SwiftUI
import AgentCore

/// Settings view for an already-registered project. Opened from the sidebar
/// project context menu. Most fields mirror New / Configure Project; the
/// working directory and custom ACP executable path can be changed here and
/// apply on the next agent start.
public struct ProjectInfoSheet: View {
    public let project: WorkspaceProjectsStore.ProjectRef
    public let onClose: () -> Void
    public var onSetWorkingDirectory: ((_ url: URL?) async -> String?)?
    public var onSetCustomExecutable: ((_ executablePath: String) async -> String?)?

    @State private var workingDirectoryURL: URL?
    @State private var workingDirectoryError: String?
    @State private var isSavingWorkingDirectory = false

    @State private var customExecutablePath: String?
    @State private var customExecutableError: String?
    @State private var isSavingCustomExecutable = false

    public init(project: WorkspaceProjectsStore.ProjectRef,
                onClose: @escaping () -> Void,
                onSetWorkingDirectory: ((_ url: URL?) async -> String?)? = nil,
                onSetCustomExecutable: ((_ executablePath: String) async -> String?)? = nil) {
        self.project = project
        self.onClose = onClose
        self.onSetWorkingDirectory = onSetWorkingDirectory
        self.onSetCustomExecutable = onSetCustomExecutable
        _workingDirectoryURL = State(initialValue: project.workingDirectoryPath.map {
            URL(fileURLWithPath: $0, isDirectory: true)
        })
        _customExecutablePath = State(initialValue: Self.customExecutable(from: project))
    }

    private var info: ProjectInfoPresentation {
        ProjectInfoPresentation.make(from: project)
    }

    private var canEditWorkingDirectory: Bool {
        project.projectType.isAgentBacked && onSetWorkingDirectory != nil
    }

    private var canEditCustomExecutable: Bool {
        onSetCustomExecutable != nil && customExecutablePath != nil
    }

    public var body: some View {
        VStack(alignment: .leading, spacing: Theme.spacing.s24) {
            VStack(alignment: .leading, spacing: Theme.spacing.s8) {
                Text("Project Info")
                    .font(Theme.typography.title)
                Text("Settings chosen when this project was created. Working directory can be changed here. Changes apply the next time the agent starts.")
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
                if let customExecutablePath {
                    customExecutableSection(path: customExecutablePath)
                }
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
    private func customExecutableSection(path: String) -> some View {
        VStack(alignment: .leading, spacing: Theme.spacing.s8) {
            Text("Executable path")
                .font(Theme.typography.caption)
                .foregroundStyle(Theme.text.secondary)
            HStack(spacing: Theme.spacing.s8) {
                Text(path)
                    .font(Theme.typography.body)
                    .foregroundStyle(Theme.text.primary)
                    .textSelection(.enabled)
                    .lineLimit(2)
                    .truncationMode(.middle)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .accessibilityLabel("Executable path")
                if canEditCustomExecutable {
                    Button("Choose…") {
                        guard let url = DesktopActions.chooseExecutablePanel(
                            prompt: "Choose Executable"
                        ) else { return }
                        Task { await saveCustomExecutable(url.path) }
                    }
                    .disabled(isSavingCustomExecutable)
                    .accessibilityLabel("Choose executable")
                }
            }
            Text("Applies the next time this project's agent starts (reopen project or Restart ACP CLI).")
                .font(Theme.typography.caption)
                .foregroundStyle(Theme.text.tertiary)
                .fixedSize(horizontal: false, vertical: true)
            if let customExecutableError {
                Text(customExecutableError)
                    .font(Theme.typography.caption)
                    .foregroundStyle(Theme.signal.warning)
                    .fixedSize(horizontal: false, vertical: true)
                    .accessibilityLabel(customExecutableError)
            }
        }
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
                }
            }
            Text("Applies the next time this project's agent starts (reopen project or New Chat).")
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

    private func saveCustomExecutable(_ path: String) async {
        guard let onSetCustomExecutable else { return }
        isSavingCustomExecutable = true
        defer { isSavingCustomExecutable = false }
        let normalized = CustomAgentInput.executablePath(from: path)
        if let error = await onSetCustomExecutable(normalized) {
            customExecutableError = error
            return
        }
        customExecutableError = nil
        customExecutablePath = normalized
    }

    private static func customExecutable(
        from project: WorkspaceProjectsStore.ProjectRef
    ) -> String? {
        guard case .custom(let ref) = project.projectType else { return nil }
        return ref.executablePath
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
