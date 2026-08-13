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
    @Binding var customExecutable: String
    @Binding var customArguments: String
    @Binding var customTransport: AgentTransportKind
    @Binding var folderKind: FolderProjectKind
    @Binding var secondaryFolderURL: URL?
    @Binding var workingDirectoryURL: URL?
    /// Shown when no override is chosen (New Project: upcoming subfolder path).
    var workingDirectoryFallbackCaption: String? = nil

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
                workingDirectoryChooser
            case .mixed:
                Picker("Default agent for new chats", selection: $mixedDefault) {
                    ForEach(SupportedBuiltInAgent.shipping) { agent in
                        Text(agent.displayLabel).tag(agent.id)
                    }
                }
                .accessibilityLabel("Default agent for mixed project type")
                workingDirectoryChooser
            case .folder:
                Picker("Folder view", selection: $folderKind) {
                    ForEach(FolderProjectKind.allCases) { kind in
                        Text(kind.displayLabel).tag(kind)
                    }
                }
                .pickerStyle(.menu)
                .accessibilityLabel("Folder view type")
                .onChange(of: folderKind) { _, kind in
                    if !kind.usesDualTreeNavigation {
                        secondaryFolderURL = nil
                    }
                }
                if folderKind.usesDualTreeNavigation {
                    dualSecondaryFolderChooser
                }
            case .custom:
                customFields
                workingDirectoryChooser
            }
        }
    }

    private var workingDirectoryChooser: some View {
        VStack(alignment: .leading, spacing: Theme.spacing.s8) {
            Text("Working directory")
                .font(Theme.typography.caption)
                .foregroundStyle(Theme.text.secondary)
            HStack(spacing: Theme.spacing.s8) {
                Text(workingDirectoryDisplayPath)
                    .font(Theme.typography.caption)
                    .foregroundStyle(workingDirectoryURL == nil
                                     ? Theme.text.tertiary
                                     : Theme.text.secondary)
                    .lineLimit(2)
                    .truncationMode(.middle)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .accessibilityLabel("Selected working directory")
                Button("Choose Folder…") {
                    guard let url = DesktopActions.chooseDirectoryPanel(
                        prompt: "Choose Working Directory"
                    ) else { return }
                    workingDirectoryURL = url
                }
                .accessibilityLabel("Choose working directory")
                if workingDirectoryURL != nil {
                    Button("Use project folder") {
                        workingDirectoryURL = nil
                    }
                    .accessibilityLabel("Use project folder as working directory")
                }
            }
            Text("Folder the agent CLI uses as its current working directory. Defaults to the project folder.")
                .font(Theme.typography.caption)
                .foregroundStyle(Theme.text.tertiary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private var workingDirectoryDisplayPath: String {
        if let workingDirectoryURL {
            return workingDirectoryURL.path
        }
        if let workingDirectoryFallbackCaption, !workingDirectoryFallbackCaption.isEmpty {
            return workingDirectoryFallbackCaption
        }
        return "Project folder (default)"
    }

    private var dualSecondaryFolderChooser: some View {
        VStack(alignment: .leading, spacing: Theme.spacing.s8) {
            Text("Compare folder")
                .font(Theme.typography.caption)
                .foregroundStyle(Theme.text.secondary)
            HStack(spacing: Theme.spacing.s8) {
                Text(secondaryFolderURL?.path ?? "No folder selected")
                    .font(Theme.typography.caption)
                    .foregroundStyle(secondaryFolderURL == nil
                                     ? Theme.text.tertiary
                                     : Theme.text.secondary)
                    .lineLimit(2)
                    .truncationMode(.middle)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .accessibilityLabel("Selected compare folder")
                Button("Choose Folder…") {
                    guard let url = DesktopActions.chooseDirectoryPanel(
                        prompt: "Choose Compare Folder"
                    ) else { return }
                    secondaryFolderURL = url
                }
                .accessibilityLabel("Choose compare folder")
            }
            if let name = secondaryFolderURL?.lastPathComponent {
                Text("Right tree root: \(name)")
                    .font(Theme.typography.caption)
                    .foregroundStyle(Theme.text.tertiary)
            }
        }
    }

    private var customFields: some View {
        VStack(alignment: .leading, spacing: Theme.spacing.s8) {
            executablePathField
            labeledField("Arguments", text: $customArguments, placeholder: "--flag value")
            Picker("Transport", selection: $customTransport) {
                Text("Interactive terminal").tag(AgentTransportKind.interactiveTerminal)
                Text("Stdio JSON-RPC").tag(AgentTransportKind.stdioJSONRPC)
                Text("Agent Client Protocol").tag(AgentTransportKind.agentClientProtocol)
            }
            .accessibilityLabel("Custom agent transport")
        }
    }

    /// Text field plus Choose… so users do not have to paste shell-quoted paths.
    private var executablePathField: some View {
        VStack(alignment: .leading, spacing: Theme.spacing.s4) {
            Text("Executable path")
                .font(Theme.typography.caption)
                .foregroundStyle(Theme.text.secondary)
            HStack(spacing: Theme.spacing.s8) {
                TextField("\(SystemPaths.usrLocalBin.path)/agent", text: $customExecutable)
                    .textFieldStyle(.roundedBorder)
                    .font(Theme.typography.body)
                    .accessibilityLabel("Executable path")
                Button("Choose…") {
                    guard let url = DesktopActions.chooseExecutablePanel(
                        prompt: "Choose Executable"
                    ) else { return }
                    customExecutable = CustomAgentInput.executablePath(from: url.path)
                }
                .accessibilityLabel("Choose executable")
            }
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
                      projectDisplayName: String,
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
            // Same label as Claude/Codex/Cursor: the project name, not a
            // separate custom-agent nickname.
            let name = projectDisplayName.trimmingCharacters(in: .whitespacesAndNewlines)
            let exe = CustomAgentInput.executablePath(from: customExecutable)
            guard !name.isEmpty, !exe.isEmpty else { return nil }
            let args = CustomAgentInput.arguments(from: customArguments)
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

            VStack(alignment: .leading, spacing: Theme.spacing.s4) {
                Text("Workspace name")
                    .font(Theme.typography.caption)
                    .foregroundStyle(Theme.text.secondary)
                TextField("my-app", text: $name)
                    .textFieldStyle(.roundedBorder)
                    .font(Theme.typography.body)
                    .accessibilityLabel("Workspace name")
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

    public let workspaceURL: URL
    public let onCancel: () -> Void
    /// Returns `nil` on success (sheet may close); otherwise an error to show under the name field.
    public let onCreate: (_ info: ProjectDraft) async -> String?
    private let random: any RandomSource
    private let fileSystem: any FileSystem

    @State private var name: String = ""
    @State private var category: ProjectTypeCategory = .singleAgent
    @State private var builtInAgent: AgentID = .claudeCode
    @State private var mixedDefault: AgentID = .claudeCode
    @State private var folderKind: FolderProjectKind = .files
    @State private var folderLocationMode: FolderLocationMode = .createInWorkspace
    @State private var folderLocation: URL?
    @State private var secondaryFolderURL: URL?
    @State private var workingDirectoryURL: URL?
    @State private var customExecutable: String = ""
    @State private var customArguments: String = ""
    @State private var customTransport: AgentTransportKind = .agentClientProtocol
    @State private var preferFreshAgentProcess = false
    @State private var isCreating = false
    @State private var createError: String?

    public init(workspaceURL: URL,
                random: any RandomSource = SystemRandomSource(),
                fileSystem: any FileSystem = SystemFileSystem(),
                onCancel: @escaping () -> Void,
                onCreate: @escaping (_ info: ProjectDraft) async -> String?) {
        self.workspaceURL = workspaceURL
        self.random = random
        self.fileSystem = fileSystem
        self.onCancel = onCancel
        self.onCreate = onCreate
    }

    private var resolvedProjectType: ProjectType? {
        ProjectTypeKind.from(category: category, builtInAgent: builtInAgent, folderKind: folderKind)
            .resolvedProjectType(
            mixedDefault: mixedDefault,
            projectDisplayName: trimmedName,
            customExecutable: customExecutable,
            customArguments: customArguments,
            customTransport: customTransport,
            idFactory: { random.uuid().uuidString }
        )
    }

    private var trimmedName: String {
        name.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// True when Create would write `<workspace>/<name>/` (not adopt an existing folder).
    private var createsWorkspaceSubfolder: Bool {
        !(category == .folder && folderLocationMode == .chooseExisting)
    }

    private var nameCollisionMessage: String? {
        guard createsWorkspaceSubfolder else { return nil }
        return ProjectFolderName.collisionMessage(
            name: trimmedName,
            in: workspaceURL,
            fileSystem: fileSystem
        )
    }

    private var nameFieldError: String? {
        nameCollisionMessage ?? createError
    }

    private var canCreate: Bool {
        guard !isCreating, resolvedProjectType != nil, !trimmedName.isEmpty else { return false }
        if category == .folder, folderLocationMode == .chooseExisting {
            guard folderLocation != nil else { return false }
        }
        if category == .folder, folderKind.usesDualTreeNavigation {
            guard let secondary = secondaryFolderURL else { return false }
            let primary = folderLocationMode == .chooseExisting
                ? folderLocation?.standardizedFileURL
                : workspaceURL.appendingPathComponent(trimmedName, isDirectory: true).standardizedFileURL
            if let primary, secondary.standardizedFileURL.path == primary.path {
                return false
            }
        }
        if category != .folder, let cwd = workingDirectoryURL {
            guard fileSystem.isDirectory(at: cwd.standardizedFileURL) else { return false }
        }
        if category == .folder, folderLocationMode == .chooseExisting {
            return true
        }
        return nameCollisionMessage == nil
    }

    private var workingDirectoryFallbackCaption: String? {
        guard category != .folder, !trimmedName.isEmpty else { return nil }
        return workspaceURL.appendingPathComponent(trimmedName, isDirectory: true).path
    }

    private var sheetSubtitle: String {
        switch category {
        case .folder:
            return "Browse files, logs, docs, modelhike, a folder tree, or a dual folder tree. Create an empty folder in this workspace or point at an existing directory."
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
                customExecutable: $customExecutable,
                customArguments: $customArguments,
                customTransport: $customTransport,
                folderKind: $folderKind,
                secondaryFolderURL: $secondaryFolderURL,
                workingDirectoryURL: $workingDirectoryURL,
                workingDirectoryFallbackCaption: workingDirectoryFallbackCaption
            )
            .disabled(isCreating)
            .onChange(of: category) { _, newCategory in
                if newCategory != .folder {
                    folderLocation = nil
                    folderLocationMode = .createInWorkspace
                    secondaryFolderURL = nil
                } else {
                    workingDirectoryURL = nil
                }
                createError = nil
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
                    .onChange(of: name) { _, _ in createError = nil }
                if category == .folder, folderLocationMode == .createInWorkspace {
                    Text("Creates an empty folder with this name inside the current workspace.")
                        .font(Theme.typography.caption)
                        .foregroundStyle(Theme.text.tertiary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                if let nameFieldError {
                    Text(nameFieldError)
                        .font(Theme.typography.caption)
                        .foregroundStyle(Theme.signal.warning)
                        .fixedSize(horizontal: false, vertical: true)
                        .accessibilityLabel(nameFieldError)
                }
            }

            if category != .folder {
                ProjectAdvancedOptions(preferFreshAgentProcess: $preferFreshAgentProcess)
                    .disabled(isCreating)
            }

            sheetFooter(
                primaryTitle: isCreating ? "Creating…" : "Create",
                primaryEnabled: canCreate,
                onCancel: onCancel,
                cancelEnabled: !isCreating
            ) {
                guard let projectType = resolvedProjectType else { return }
                if let collision = nameCollisionMessage {
                    createError = collision
                    return
                }
                isCreating = true
                defer { isCreating = false }
                let folderURL: URL? = (category == .folder && folderLocationMode == .chooseExisting)
                    ? folderLocation
                    : nil
                if folderKind.usesDualTreeNavigation, let secondary = secondaryFolderURL {
                    let primary = (folderURL
                        ?? workspaceURL.appendingPathComponent(trimmedName, isDirectory: true))
                        .standardizedFileURL
                    if secondary.standardizedFileURL.path == primary.path {
                        createError = "The compare folder must be different from the project folder."
                        return
                    }
                }
                if category != .folder, let cwd = workingDirectoryURL,
                   !fileSystem.isDirectory(at: cwd.standardizedFileURL) {
                    createError = "Working directory \(cwd.path) is missing or not a folder."
                    return
                }
                let createdError = await onCreate(ProjectDraft(
                    name: trimmedName,
                    projectType: projectType,
                    preferFreshAgentProcess: preferFreshAgentProcess,
                    existingFolderURL: folderURL,
                    secondaryFolderURL: folderKind.usesDualTreeNavigation ? secondaryFolderURL : nil,
                    workingDirectoryURL: category == .folder ? nil : workingDirectoryURL
                ))
                if let createdError {
                    createError = createdError
                }
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
    public let onConfirm: (_ info: ProjectDraft) -> Void
    private let random: any RandomSource

    @State private var category: ProjectTypeCategory = .singleAgent
    @State private var builtInAgent: AgentID = .claudeCode
    @State private var mixedDefault: AgentID = .claudeCode
    @State private var folderKind: FolderProjectKind = .files
    @State private var secondaryFolderURL: URL?
    @State private var workingDirectoryURL: URL?
    @State private var customExecutable: String = ""
    @State private var customArguments: String = ""
    @State private var customTransport: AgentTransportKind = .agentClientProtocol
    @State private var preferFreshAgentProcess = false
    @State private var configureError: String?

    public init(projectURL: URL,
                random: any RandomSource = SystemRandomSource(),
                onCancel: @escaping () -> Void,
                onConfirm: @escaping (_ info: ProjectDraft) -> Void) {
        self.projectURL = projectURL
        self.random = random
        self.onCancel = onCancel
        self.onConfirm = onConfirm
        // Selected folder is the default working directory (stored as nil when
        // equal to the project path after normalize).
        _workingDirectoryURL = State(initialValue: projectURL)
    }

    private var resolvedProjectType: ProjectType? {
        ProjectTypeKind.from(category: category, builtInAgent: builtInAgent, folderKind: folderKind)
            .resolvedProjectType(
            mixedDefault: mixedDefault,
            projectDisplayName: projectURL.lastPathComponent,
            customExecutable: customExecutable,
            customArguments: customArguments,
            customTransport: customTransport,
            idFactory: { random.uuid().uuidString }
        )
    }

    private var canOpen: Bool {
        guard resolvedProjectType != nil else { return false }
        if category == .folder, folderKind.usesDualTreeNavigation {
            guard let secondary = secondaryFolderURL else { return false }
            return secondary.standardizedFileURL.path != projectURL.standardizedFileURL.path
        }
        if category != .folder, let cwd = workingDirectoryURL {
            return SystemFileSystem().isDirectory(at: cwd.standardizedFileURL)
        }
        return true
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
                customExecutable: $customExecutable,
                customArguments: $customArguments,
                customTransport: $customTransport,
                folderKind: $folderKind,
                secondaryFolderURL: $secondaryFolderURL,
                workingDirectoryURL: $workingDirectoryURL,
                workingDirectoryFallbackCaption: projectURL.path
            )
            .onChange(of: category) { _, newCategory in
                if newCategory == .folder {
                    workingDirectoryURL = nil
                } else if workingDirectoryURL == nil {
                    workingDirectoryURL = projectURL
                }
            }

            if category != .folder {
                ProjectAdvancedOptions(preferFreshAgentProcess: $preferFreshAgentProcess)
            }

            if let configureError {
                Text(configureError)
                    .font(Theme.typography.caption)
                    .foregroundStyle(Theme.signal.warning)
                    .fixedSize(horizontal: false, vertical: true)
                    .accessibilityLabel(configureError)
            }

            sheetFooter(primaryTitle: "Open", primaryEnabled: canOpen, onCancel: onCancel) {
                guard let projectType = resolvedProjectType else { return }
                if folderKind.usesDualTreeNavigation {
                    guard let secondary = secondaryFolderURL else {
                        configureError = "Choose a compare folder for the dual folder tree."
                        return
                    }
                    if secondary.standardizedFileURL.path == projectURL.standardizedFileURL.path {
                        configureError = "The compare folder must be different from the project folder."
                        return
                    }
                }
                if category != .folder, let cwd = workingDirectoryURL,
                   !SystemFileSystem().isDirectory(at: cwd.standardizedFileURL) {
                    configureError = "Working directory \(cwd.path) is missing or not a folder."
                    return
                }
                onConfirm(ProjectDraft(
                    name: projectURL.lastPathComponent,
                    projectType: projectType,
                    preferFreshAgentProcess: preferFreshAgentProcess,
                    existingFolderURL: projectURL,
                    secondaryFolderURL: folderKind.usesDualTreeNavigation ? secondaryFolderURL : nil,
                    workingDirectoryURL: category == .folder ? nil : workingDirectoryURL
                ))
            }
        }
        .padding(Theme.spacing.s24)
        .frame(minWidth: Theme.layout.openProjectMinWidth,
               maxWidth: Theme.layout.openProjectMaxWidth)
        .fixedSize(horizontal: false, vertical: true)
        .background(Theme.surface.canvas)
    }
}

/// Collapsible Advanced options shared by New / Configure Project sheets.
struct ProjectAdvancedOptions: View {
    @Binding var preferFreshAgentProcess: Bool

    var body: some View {
        DisclosureGroup("Advanced") {
            VStack(alignment: .leading, spacing: Theme.spacing.s8) {
                Toggle("Launch new agent instance", isOn: $preferFreshAgentProcess)
                    .accessibilityLabel("Launch new agent instance")
                Text("When off, Codemixer keeps one agent CLI running per project and reuses it when you return — including New Chat and session switches in that project. When on, opening this project always starts a fresh CLI.")
                    .font(Theme.typography.caption)
                    .foregroundStyle(Theme.text.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .padding(.top, Theme.spacing.s8)
        }
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
