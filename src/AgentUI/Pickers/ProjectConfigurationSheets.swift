import SwiftUI
import AgentCore
import AgentProtocol

/// Shared agent-mode editor used by New Project and first-open configuration
/// for folders that do not yet have `.codemixer/project.json`.
///
/// Alerts cannot host pickers / text fields reliably on macOS — this form is
/// always presented in a sheet so Claude / Codex / Mixed / Custom controls are
/// actually reachable.
struct ProjectAgentModeForm: View {
    @Binding var selectedKind: ProjectAgentModeKind
    @Binding var mixedDefault: AgentID
    @Binding var customDisplayName: String
    @Binding var customExecutable: String
    @Binding var customArguments: String
    @Binding var customTransport: AgentTransportKind

    var body: some View {
        VStack(alignment: .leading, spacing: Theme.spacing.s16) {
            Picker("Agent mode", selection: $selectedKind) {
                ForEach(ProjectAgentModeKind.allCases) { kind in
                    Text(kind.label).tag(kind)
                }
            }
            .pickerStyle(.segmented)
            .accessibilityLabel("Project agent mode")

            switch selectedKind {
            case .claudeCode, .codex:
                EmptyView()
            case .mixed:
                Picker("Default agent for new chats", selection: $mixedDefault) {
                    Text("Claude Code").tag(AgentID.claudeCode)
                    Text("Codex").tag(AgentID.codex)
                }
                .accessibilityLabel("Default agent for mixed mode")
            case .custom:
                customFields
            }
        }
    }

    private var customFields: some View {
        VStack(alignment: .leading, spacing: Theme.spacing.s8) {
            labeledField("Display name", text: $customDisplayName, placeholder: "My Agent")
            labeledField("Executable path", text: $customExecutable, placeholder: "/usr/local/bin/agent")
            labeledField("Arguments", text: $customArguments, placeholder: "--flag value")
            Picker("Transport", selection: $customTransport) {
                Text("Interactive terminal").tag(AgentTransportKind.interactiveTerminal)
                Text("Stdio JSON-RPC").tag(AgentTransportKind.stdioJSONRPC)
                Text("Agent Client Protocol").tag(AgentTransportKind.agentClientProtocol)
            }
            .accessibilityLabel("Custom agent transport")
        }
    }

    private func labeledField(_ title: String,
                              text: Binding<String>,
                              placeholder: String) -> some View {
        VStack(alignment: .leading, spacing: Theme.spacing.s4) {
            Text(title)
                .font(Theme.typography.caption)
                .foregroundStyle(Theme.text.secondary)
            TextField(placeholder, text: text)
                .textFieldStyle(.roundedBorder)
                .font(Theme.typography.body)
                .accessibilityLabel(title)
        }
    }
}

/// Discrete picker cases for `ProjectAgentMode` (associated values live in
/// sibling bindings, not in the selection enum).
enum ProjectAgentModeKind: String, CaseIterable, Identifiable, Hashable {
    case claudeCode
    case codex
    case mixed
    case custom

    var id: String { rawValue }

    var label: String {
        switch self {
        case .claudeCode: return "Claude"
        case .codex: return "Codex"
        case .mixed: return "Mixed"
        case .custom: return "Custom"
        }
    }

    func resolvedMode(mixedDefault: AgentID,
                      customDisplayName: String,
                      customExecutable: String,
                      customArguments: String,
                      customTransport: AgentTransportKind,
                      idFactory: () -> String) -> ProjectAgentMode? {
        switch self {
        case .claudeCode:
            return .claudeCode
        case .codex:
            return .codex
        case .mixed:
            return .mixed(defaultAgent: mixedDefault)
        case .custom:
            let name = customDisplayName.trimmingCharacters(in: .whitespacesAndNewlines)
            let exe = customExecutable.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !name.isEmpty, !exe.isEmpty else { return nil }
            let args = customArguments
                .split(whereSeparator: \.isWhitespace)
                .map(String.init)
                .filter { !$0.isEmpty }
            let transport: AgentTransportDescriptor = switch customTransport {
            case .interactiveTerminal: .interactiveTerminal
            case .stdioJSONRPC: .stdioJSONRPC
            case .agentClientProtocol: .agentClientProtocol
            }
            return .custom(CustomAgentRef(
                id: idFactory(),
                displayName: name,
                transport: transport,
                executablePath: exe,
                arguments: args
            ))
        }
    }
}

/// Creates a new workspace folder on disk and opens it.
///
/// Collects a display/folder name and a parent location via Choose Folder….
/// Agent mode is chosen later via **New Project** (or Configure when opening
/// an existing folder that has no `.codemixer/project.json`).
public struct NewWorkspaceSheet: View {
    public let onCancel: () -> Void
    public let onCreate: (_ name: String, _ parentDirectory: URL) -> Void

    @State private var name: String = ""
    @State private var parentDirectory: URL?

    public init(onCancel: @escaping () -> Void,
                onCreate: @escaping (_ name: String, _ parentDirectory: URL) -> Void) {
        self.onCancel = onCancel
        self.onCreate = onCreate
    }

    private var trimmedName: String {
        name.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private var canCreate: Bool {
        !trimmedName.isEmpty
            && !trimmedName.contains("/")
            && !trimmedName.contains("\\")
            && trimmedName != "."
            && trimmedName != ".."
            && parentDirectory != nil
    }

    private var previewPath: String? {
        guard let parent = parentDirectory else { return nil }
        return parent.appendingPathComponent(trimmedName.isEmpty ? "…" : trimmedName,
                                             isDirectory: true).path
    }

    public var body: some View {
        VStack(alignment: .leading, spacing: Theme.spacing.s24) {
            sheetHeader(
                title: "New Workspace",
                subtitle: "Creates a folder at the chosen location and opens it. Add projects (with agent mode) via File → New Project…"
            )

            VStack(alignment: .leading, spacing: Theme.spacing.s4) {
                Text("Workspace name")
                    .font(Theme.typography.caption)
                    .foregroundStyle(Theme.text.secondary)
                TextField("my-app", text: $name)
                    .textFieldStyle(.roundedBorder)
                    .font(Theme.typography.body)
                    .accessibilityLabel("Workspace name")
            }

            VStack(alignment: .leading, spacing: Theme.spacing.s8) {
                Text("Location")
                    .font(Theme.typography.caption)
                    .foregroundStyle(Theme.text.secondary)
                HStack(spacing: Theme.spacing.s8) {
                    Text(parentDirectory?.path ?? "No folder selected")
                        .font(Theme.typography.caption)
                        .foregroundStyle(parentDirectory == nil
                                         ? Theme.text.tertiary
                                         : Theme.text.secondary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .accessibilityLabel("Selected location")
                    Button("Choose Folder…") {
                        if let url = DesktopActions.chooseDirectoryPanel(prompt: "Choose Location") {
                            parentDirectory = url
                        }
                    }
                    .accessibilityLabel("Choose workspace location")
                }
                if let previewPath {
                    Text(previewPath)
                        .font(Theme.typography.caption)
                        .foregroundStyle(Theme.text.tertiary)
                        .lineLimit(2)
                        .truncationMode(.middle)
                        .accessibilityLabel("Workspace will be created at \(previewPath)")
                }
            }

            sheetFooter(primaryTitle: "Create", primaryEnabled: canCreate, onCancel: onCancel) {
                guard let parent = parentDirectory else { return }
                onCreate(trimmedName, parent)
            }
        }
        .padding(Theme.spacing.s24)
        .frame(minWidth: Theme.layout.agentPickerMinWidth)
        .background(Theme.surface.canvas)
    }
}

/// Creates a subfolder project inside the current workspace.
public struct NewProjectSheet: View {
    public let onCancel: () -> Void
    public let onCreate: (String, ProjectAgentMode) -> Void

    @State private var name: String = ""
    @State private var kind: ProjectAgentModeKind = .claudeCode
    @State private var mixedDefault: AgentID = .claudeCode
    @State private var customDisplayName: String = ""
    @State private var customExecutable: String = ""
    @State private var customArguments: String = ""
    @State private var customTransport: AgentTransportKind = .agentClientProtocol

    public init(onCancel: @escaping () -> Void,
                onCreate: @escaping (String, ProjectAgentMode) -> Void) {
        self.onCancel = onCancel
        self.onCreate = onCreate
    }

    private var resolvedMode: ProjectAgentMode? {
        kind.resolvedMode(
            mixedDefault: mixedDefault,
            customDisplayName: customDisplayName,
            customExecutable: customExecutable,
            customArguments: customArguments,
            customTransport: customTransport,
            idFactory: { UUID().uuidString }
        )
    }

    private var canCreate: Bool {
        !name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && resolvedMode != nil
    }

    public var body: some View {
        VStack(alignment: .leading, spacing: Theme.spacing.s24) {
            sheetHeader(
                title: "New Project",
                subtitle: "Creates a subfolder in the current workspace and writes agent mode to `.codemixer/project.json`."
            )

            VStack(alignment: .leading, spacing: Theme.spacing.s4) {
                Text("Project name")
                    .font(Theme.typography.caption)
                    .foregroundStyle(Theme.text.secondary)
                TextField("api", text: $name)
                    .textFieldStyle(.roundedBorder)
                    .font(Theme.typography.body)
                    .accessibilityLabel("Project name")
            }

            ProjectAgentModeForm(
                selectedKind: $kind,
                mixedDefault: $mixedDefault,
                customDisplayName: $customDisplayName,
                customExecutable: $customExecutable,
                customArguments: $customArguments,
                customTransport: $customTransport
            )

            sheetFooter(primaryTitle: "Create", primaryEnabled: canCreate, onCancel: onCancel) {
                guard let mode = resolvedMode else { return }
                let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
                onCreate(trimmed, mode)
            }
        }
        .padding(Theme.spacing.s24)
        .frame(minWidth: Theme.layout.agentPickerMinWidth, minHeight: Theme.layout.agentPickerMinHeight)
        .background(Theme.surface.canvas)
    }
}

/// First-open configuration when a chosen folder has no stored agent mode.
public struct ConfigureProjectSheet: View {
    public let projectURL: URL
    public let onCancel: () -> Void
    public let onConfirm: (ProjectAgentMode) -> Void

    @State private var kind: ProjectAgentModeKind = .claudeCode
    @State private var mixedDefault: AgentID = .claudeCode
    @State private var customDisplayName: String = ""
    @State private var customExecutable: String = ""
    @State private var customArguments: String = ""
    @State private var customTransport: AgentTransportKind = .agentClientProtocol

    public init(projectURL: URL,
                onCancel: @escaping () -> Void,
                onConfirm: @escaping (ProjectAgentMode) -> Void) {
        self.projectURL = projectURL
        self.onCancel = onCancel
        self.onConfirm = onConfirm
    }

    private var resolvedMode: ProjectAgentMode? {
        kind.resolvedMode(
            mixedDefault: mixedDefault,
            customDisplayName: customDisplayName,
            customExecutable: customExecutable,
            customArguments: customArguments,
            customTransport: customTransport,
            idFactory: { UUID().uuidString }
        )
    }

    public var body: some View {
        VStack(alignment: .leading, spacing: Theme.spacing.s24) {
            sheetHeader(
                title: "Configure Project",
                subtitle: "\(projectURL.lastPathComponent) has no saved agent mode yet. Pick one to write `.codemixer/project.json` and open."
            )

            ProjectAgentModeForm(
                selectedKind: $kind,
                mixedDefault: $mixedDefault,
                customDisplayName: $customDisplayName,
                customExecutable: $customExecutable,
                customArguments: $customArguments,
                customTransport: $customTransport
            )

            sheetFooter(primaryTitle: "Open", primaryEnabled: resolvedMode != nil, onCancel: onCancel) {
                guard let mode = resolvedMode else { return }
                onConfirm(mode)
            }
        }
        .padding(Theme.spacing.s24)
        .frame(minWidth: Theme.layout.agentPickerMinWidth, minHeight: Theme.layout.agentPickerMinHeight)
        .background(Theme.surface.canvas)
    }
}

// MARK: - Shared chrome

@MainActor
private func sheetHeader(title: String, subtitle: String) -> some View {
    VStack(alignment: .leading, spacing: Theme.spacing.s8) {
        Text(title)
            .font(Theme.typography.title)
        Text(subtitle)
            .font(Theme.typography.caption)
            .foregroundStyle(Theme.text.secondary)
            .fixedSize(horizontal: false, vertical: true)
    }
}

@MainActor
private func sheetFooter(primaryTitle: String,
                         primaryEnabled: Bool,
                         onCancel: @escaping () -> Void,
                         primaryAction: @escaping () -> Void) -> some View {
    HStack {
        Spacer()
        Button("Cancel", action: onCancel)
            .keyboardShortcut(.cancelAction)
        Button(primaryTitle, action: primaryAction)
            .buttonStyle(.borderedProminent)
            .keyboardShortcut(.defaultAction)
            .disabled(!primaryEnabled)
    }
}
