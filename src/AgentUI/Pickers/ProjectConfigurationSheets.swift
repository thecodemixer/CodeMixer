import SwiftUI
import AgentCore
import AgentProtocol

/// Shared project-type editor used by New Project and first-open configuration
/// for folders that do not yet have `.codemixer/project.json`.
///
/// Alerts cannot host pickers / text fields reliably on macOS — this form is
/// always presented in a titled window so built-in / Mixed / Custom controls
/// are actually reachable.
struct ProjectTypeForm: View {
    @Binding var category: ProjectTypeCategory
    @Binding var builtInAgent: AgentID
    @Binding var mixedDefault: AgentID
    @Binding var customDisplayName: String
    @Binding var customExecutable: String
    @Binding var customArguments: String
    @Binding var customTransport: AgentTransportKind
    @Binding var folderKind: FolderProjectKind

    var body: some View {
        VStack(alignment: .leading, spacing: Theme.spacing.s16) {
            Picker("Project type", selection: $category) {
                ForEach(ProjectTypeCategory.allCases) { kind in
                    Text(kind.label).tag(kind)
                }
            }
            .pickerStyle(.menu)
            .accessibilityLabel("Project type")

            switch category {
            case .singleAgent:
                Picker("Agent", selection: $builtInAgent) {
                    ForEach(SupportedBuiltInAgent.shipping) { agent in
                        Text(agent.displayLabel).tag(agent.id)
                    }
                }
                .pickerStyle(.menu)
                .accessibilityLabel("Agent CLI")
            case .mixed:
                Picker("Default agent for new chats", selection: $mixedDefault) {
                    ForEach(SupportedBuiltInAgent.shipping) { agent in
                        Text(agent.displayLabel).tag(agent.id)
                    }
                }
                .accessibilityLabel("Default agent for mixed project type")
            case .folder:
                Picker("Folder view", selection: $folderKind) {
                    ForEach(FolderProjectKind.allCases) { kind in
                        Text(kind.displayLabel).tag(kind)
                    }
                }
                .pickerStyle(.menu)
                .accessibilityLabel("Folder view type")
            case .custom:
                customFields
            }
        }
    }

    private var customFields: some View {
        VStack(alignment: .leading, spacing: Theme.spacing.s8) {
            labeledField("Display name", text: $customDisplayName, placeholder: "My Agent")
            labeledField("Executable path", text: $customExecutable, placeholder: "\(SystemPaths.usrLocalBin.path)/agent")
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

/// Top-level New / Configure Project choice before agent-specific fields.
enum ProjectTypeCategory: String, CaseIterable, Hashable, Identifiable {
    case singleAgent
    case mixed
    case folder
    case custom

    var id: String { rawValue }

    var label: String {
        switch self {
        case .singleAgent: return "Single agent"
        case .mixed: return "Mixed"
        case .folder: return "Folder"
        case .custom: return "Custom"
        }
    }
}

/// Discrete picker cases for `ProjectType`.
///
/// Built-in agents come from `SupportedBuiltInAgent.shipping` so adding a new
/// shipping CLI does not require rewriting New/Configure Project sheets.
enum ProjectTypeKind: Hashable, Identifiable {
    case builtIn(AgentID)
    case mixed
    case folder(FolderProjectKind)
    case custom

    var id: String {
        switch self {
        case .builtIn(let id): return "builtin-\(id.rawValue)"
        case .mixed: return "mixed"
        case .folder(let kind): return "folder-\(kind.rawValue)"
        case .custom: return "custom"
        }
    }

    var category: ProjectTypeCategory {
        switch self {
        case .builtIn: return .singleAgent
        case .mixed: return .mixed
        case .folder: return .folder
        case .custom: return .custom
        }
    }

    var builtInAgentID: AgentID? {
        if case .builtIn(let id) = self { return id }
        return nil
    }

    static func from(category: ProjectTypeCategory,
                     builtInAgent: AgentID,
                     folderKind: FolderProjectKind) -> ProjectTypeKind {
        switch category {
        case .singleAgent: return .builtIn(builtInAgent)
        case .mixed: return .mixed
        case .folder: return .folder(folderKind)
        case .custom: return .custom
        }
    }

    var label: String {
        switch self {
        case .builtIn(let id):
            return SupportedBuiltInAgent.entry(for: id)?.displayLabel ?? id.rawValue
        case .mixed: return "Mixed"
        case .folder(let kind): return kind.displayLabel
        case .custom: return "Custom"
        }
    }

    static var allCases: [ProjectTypeKind] {
        SupportedBuiltInAgent.shipping.map { .builtIn($0.id) }
            + [.mixed]
            + FolderProjectKind.allCases.map { .folder($0) }
            + [.custom]
    }

    func resolvedProjectType(mixedDefault: AgentID,
                      customDisplayName: String,
                      customExecutable: String,
                      customArguments: String,
                      customTransport: AgentTransportKind,
                      idFactory: () -> String) -> ProjectType? {
        switch self {
        case .builtIn(let id):
            return SupportedBuiltInAgent.entry(for: id)?.projectType
        case .mixed:
            return .mixed(defaultAgent: mixedDefault)
        case .folder(let kind):
            return .folder(kind)
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
/// Project type is chosen later via **New Project** (or Configure when opening
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
                subtitle: "Creates a folder at the chosen location and opens it. Add projects (with a project type) via File → New Project…"
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
        .frame(minWidth: Theme.layout.agentPickerMinWidth,
               maxWidth: Theme.layout.agentPickerMaxWidth)
        .fixedSize(horizontal: false, vertical: true)
        .background(Theme.surface.canvas)
    }
}

/// Creates a project in the current workspace.
///
/// Agent types create a named subfolder. Folder types can either create an empty
/// subfolder under the workspace or register an existing directory via Choose Folder….
public struct NewProjectSheet: View {
    /// Where a folder project’s files live.
    private enum FolderLocationMode: String, CaseIterable, Identifiable {
        case createInWorkspace
        case chooseExisting

        var id: String { rawValue }

        var label: String {
            switch self {
            case .createInWorkspace: return "Create empty folder in workspace"
            case .chooseExisting: return "Use existing folder…"
            }
        }
    }

    public let onCancel: () -> Void
    /// `folderURL` is set only when registering an existing directory for a folder type.
    public let onCreate: (_ name: String, _ projectType: ProjectType, _ folderURL: URL?) async -> Void

    @State private var name: String = ""
    @State private var category: ProjectTypeCategory = .singleAgent
    @State private var builtInAgent: AgentID = .claudeCode
    @State private var mixedDefault: AgentID = .claudeCode
    @State private var folderKind: FolderProjectKind = .files
    @State private var folderLocationMode: FolderLocationMode = .createInWorkspace
    @State private var folderLocation: URL?
    @State private var customDisplayName: String = ""
    @State private var customExecutable: String = ""
    @State private var customArguments: String = ""
    @State private var customTransport: AgentTransportKind = .agentClientProtocol
    @State private var isCreating = false

    public init(onCancel: @escaping () -> Void,
                onCreate: @escaping (_ name: String, _ projectType: ProjectType, _ folderURL: URL?) async -> Void) {
        self.onCancel = onCancel
        self.onCreate = onCreate
    }

    private var resolvedProjectType: ProjectType? {
        ProjectTypeKind.from(category: category, builtInAgent: builtInAgent, folderKind: folderKind)
            .resolvedProjectType(
            mixedDefault: mixedDefault,
            customDisplayName: customDisplayName,
            customExecutable: customExecutable,
            customArguments: customArguments,
            customTransport: customTransport,
            idFactory: { UUID().uuidString }
        )
    }

    private var trimmedName: String {
        name.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private var canCreate: Bool {
        guard !isCreating, resolvedProjectType != nil, !trimmedName.isEmpty else { return false }
        if category == .folder, folderLocationMode == .chooseExisting {
            return folderLocation != nil
        }
        return true
    }

    private var sheetSubtitle: String {
        switch category {
        case .folder:
            return "Browse files, logs, docs, or modelhike. Create an empty folder in this workspace or point at an existing directory."
        case .singleAgent, .mixed, .custom:
            return "Creates a subfolder in the current workspace and writes project type to `.codemixer/project.json`."
        }
    }

    public var body: some View {
        VStack(alignment: .leading, spacing: Theme.spacing.s24) {
            sheetHeader(
                title: "New Project",
                subtitle: sheetSubtitle
            )

            ProjectTypeForm(
                category: $category,
                builtInAgent: $builtInAgent,
                mixedDefault: $mixedDefault,
                customDisplayName: $customDisplayName,
                customExecutable: $customExecutable,
                customArguments: $customArguments,
                customTransport: $customTransport,
                folderKind: $folderKind
            )
            .disabled(isCreating)
            .onChange(of: category) { _, newCategory in
                if newCategory != .folder {
                    folderLocation = nil
                    folderLocationMode = .createInWorkspace
                }
            }

            if category == .folder {
                folderLocationSection
            }

            VStack(alignment: .leading, spacing: Theme.spacing.s4) {
                Text(category == .folder ? "Display name" : "Project name")
                    .font(Theme.typography.caption)
                    .foregroundStyle(Theme.text.secondary)
                TextField(category == .folder ? "docs" : "api", text: $name)
                    .textFieldStyle(.roundedBorder)
                    .font(Theme.typography.body)
                    .disabled(isCreating)
                    .accessibilityLabel(category == .folder ? "Display name" : "Project name")
                if category == .folder, folderLocationMode == .createInWorkspace {
                    Text("Creates an empty folder with this name inside the current workspace.")
                        .font(Theme.typography.caption)
                        .foregroundStyle(Theme.text.tertiary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }

            sheetFooter(
                primaryTitle: isCreating ? "Creating…" : "Create",
                primaryEnabled: canCreate,
                onCancel: onCancel,
                cancelEnabled: !isCreating
            ) {
                guard let projectType = resolvedProjectType else { return }
                isCreating = true
                defer { isCreating = false }
                let folderURL: URL? = (category == .folder && folderLocationMode == .chooseExisting)
                    ? folderLocation
                    : nil
                await onCreate(trimmedName, projectType, folderURL)
            }
        }
        .padding(Theme.spacing.s24)
        .frame(minWidth: Theme.layout.agentPickerMinWidth,
               maxWidth: Theme.layout.agentPickerMaxWidth)
        .fixedSize(horizontal: false, vertical: true)
        .background(Theme.surface.canvas)
        .interactiveDismissDisabled(isCreating)
    }

    private var folderLocationSection: some View {
        VStack(alignment: .leading, spacing: Theme.spacing.s8) {
            Text("Folder location")
                .font(Theme.typography.caption)
                .foregroundStyle(Theme.text.secondary)
            Picker("Folder location", selection: $folderLocationMode) {
                ForEach(FolderLocationMode.allCases) { mode in
                    Text(mode.label).tag(mode)
                }
            }
            .pickerStyle(.radioGroup)
            .disabled(isCreating)
            .accessibilityLabel("Folder location")
            .onChange(of: folderLocationMode) { _, mode in
                if mode == .createInWorkspace {
                    folderLocation = nil
                }
            }

            if folderLocationMode == .chooseExisting {
                HStack(spacing: Theme.spacing.s8) {
                    Text(folderLocation?.path ?? "No folder selected")
                        .font(Theme.typography.caption)
                        .foregroundStyle(folderLocation == nil
                                         ? Theme.text.tertiary
                                         : Theme.text.secondary)
                        .lineLimit(2)
                        .truncationMode(.middle)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .accessibilityLabel("Selected folder location")
                    Button("Choose Folder…") {
                        guard let url = DesktopActions.chooseDirectoryPanel(prompt: "Choose Folder") else {
                            return
                        }
                        let previousLeaf = folderLocation?.lastPathComponent
                        folderLocation = url
                        if trimmedName.isEmpty || trimmedName == previousLeaf {
                            name = url.lastPathComponent
                        }
                    }
                    .disabled(isCreating)
                    .accessibilityLabel("Choose folder location")
                }
            }
        }
    }
}

/// First-open configuration when a chosen folder has no stored project type.
public struct ConfigureProjectSheet: View {
    public let projectURL: URL
    public let onCancel: () -> Void
    public let onConfirm: (ProjectType) -> Void

    @State private var category: ProjectTypeCategory = .singleAgent
    @State private var builtInAgent: AgentID = .claudeCode
    @State private var mixedDefault: AgentID = .claudeCode
    @State private var folderKind: FolderProjectKind = .files
    @State private var customDisplayName: String = ""
    @State private var customExecutable: String = ""
    @State private var customArguments: String = ""
    @State private var customTransport: AgentTransportKind = .agentClientProtocol

    public init(projectURL: URL,
                onCancel: @escaping () -> Void,
                onConfirm: @escaping (ProjectType) -> Void) {
        self.projectURL = projectURL
        self.onCancel = onCancel
        self.onConfirm = onConfirm
    }

    private var resolvedProjectType: ProjectType? {
        ProjectTypeKind.from(category: category, builtInAgent: builtInAgent, folderKind: folderKind)
            .resolvedProjectType(
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
                subtitle: "\(projectURL.lastPathComponent) has no saved project type yet. Pick a project type to write `.codemixer/project.json` and open."
            )

            ProjectTypeForm(
                category: $category,
                builtInAgent: $builtInAgent,
                mixedDefault: $mixedDefault,
                customDisplayName: $customDisplayName,
                customExecutable: $customExecutable,
                customArguments: $customArguments,
                customTransport: $customTransport,
                folderKind: $folderKind
            )

            sheetFooter(primaryTitle: "Open", primaryEnabled: resolvedProjectType != nil, onCancel: onCancel) {
                guard let projectType = resolvedProjectType else { return }
                onConfirm(projectType)
            }
        }
        .padding(Theme.spacing.s24)
        .frame(minWidth: Theme.layout.openProjectMinWidth,
               maxWidth: Theme.layout.openProjectMaxWidth)
        .fixedSize(horizontal: false, vertical: true)
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
                         cancelEnabled: Bool = true,
                         primaryAction: @escaping () async -> Void) -> some View {
    HStack {
        Spacer()
        Button("Cancel", action: onCancel)
            .keyboardShortcut(.cancelAction)
            .disabled(!cancelEnabled)
        Button(primaryTitle) {
            Task { await primaryAction() }
        }
        .buttonStyle(.borderedProminent)
        .keyboardShortcut(.defaultAction)
        .disabled(!primaryEnabled)
    }
}
