import SwiftUI
import AgentCore
import AgentProtocol

/// Project picker shown when the workspace isn't set yet, or via File → Open Project.
///
/// Recents only — agent mode is resolved from `<project>/.codemixer/project.json`
/// (or the workspace index). Folders without a stored mode are handed back to
/// the caller so they can present a configuration sheet.
public struct ProjectPickerView: View {
    public let recent: [SessionStore.ProjectRecord]
    public let onOpen: (URL, _ resumeSessionID: String?) -> Void

    @State private var selection: SessionStore.ProjectRecord?
    @State private var searchText: String = ""

    public init(recent: [SessionStore.ProjectRecord],
                onOpen: @escaping (URL, _ resumeSessionID: String?) -> Void) {
        self.recent = recent
        self.onOpen = onOpen
    }

    private var filtered: [SessionStore.ProjectRecord] {
        guard !searchText.isEmpty else { return recent }
        return recent.filter {
            $0.displayName.localizedCaseInsensitiveContains(searchText) ||
            $0.path.localizedCaseInsensitiveContains(searchText) ||
            ($0.lastSessionID ?? "").localizedCaseInsensitiveContains(searchText)
        }
    }

    public var body: some View {
        VStack(spacing: Theme.spacing.s24) {
            VStack(spacing: Theme.spacing.s8) {
                Image(systemName: "folder.fill.badge.gearshape")
                    .accessibilityHidden(true)
                    .font(Theme.typography.heroIcon)
                    .foregroundStyle(Theme.text.tertiary)
                Text("Open a project")
                    .font(Theme.typography.title)
                Text("Pick a recent folder, or choose one from disk.")
                    .font(Theme.typography.caption)
                    .foregroundStyle(Theme.text.secondary)
            }
            .padding(.top, Theme.spacing.s32)

            if recent.isEmpty {
                Text("No recent projects yet.")
                    .foregroundStyle(Theme.text.secondary)
            } else {
                HStack {
                    Image(systemName: "magnifyingglass")
                        .accessibilityLabel("Search")
                        .foregroundStyle(Theme.text.tertiary)
                    TextField("Filter projects…", text: $searchText)
                        .textFieldStyle(.plain)
                        .font(Theme.typography.body)
                    if !searchText.isEmpty {
                        Button { searchText = "" } label: {
                            Image(systemName: "xmark.circle.fill")
                                .foregroundStyle(Theme.text.tertiary)
                        }
                        .buttonStyle(.plain)
                        .accessibilityLabel("Clear filter")
                    }
                }
                .padding(Theme.spacing.s8)
                .background(Theme.surface.bubble,
                            in: RoundedRectangle(cornerRadius: Theme.corner.small))
                .padding(.horizontal)

                List(selection: $selection) {
                    Section(filtered.isEmpty ? "No results" : "Recent") {
                        ForEach(filtered, id: \.path) { project in
                            HStack {
                                Image(systemName: "folder")
                                    .accessibilityLabel("Project folder")
                                    .foregroundStyle(Theme.text.secondary)
                                VStack(alignment: .leading) {
                                    HStack(spacing: Theme.spacing.s8) {
                                        Text(project.displayName).font(Theme.typography.body)
                                        if let badge = memoryFileBadge(at: project.path) {
                                            Text(badge)
                                                .font(Theme.typography.caption)
                                                .foregroundStyle(Theme.signal.info)
                                                .padding(.horizontal, Theme.spacing.s4)
                                                .background(Theme.signal.info.opacity(Theme.opacity.subtle), in: .capsule)
                                                .help("Project has \(badge) in its root")
                                                .accessibilityLabel("Has \(badge)")
                                        }
                                    }
                                    Text(project.path)
                                        .font(Theme.typography.caption)
                                        .foregroundStyle(Theme.text.tertiary)
                                        .lineLimit(1).truncationMode(.middle)
                                }
                                Spacer()
                                if project.lastSessionID != nil {
                                    Tag(label: "Resume", system: "arrow.uturn.left.circle")
                                }
                            }
                            .tag(project)
                            .accessibilityLabel("\(project.displayName), \(project.path)")
                            .contextMenu {
                                Button("Open") {
                                    open(URL(fileURLWithPath: project.path), resumeSessionID: nil)
                                }
                                if let last = project.lastSessionID {
                                    Button("Resume last session") {
                                        open(URL(fileURLWithPath: project.path), resumeSessionID: last)
                                    }
                                }
                                Divider()
                                Button("Reveal in Finder") {
                                    DesktopActions.revealInFinder(URL(fileURLWithPath: project.path))
                                }
                            }
                        }
                    }
                }
                .listStyle(.inset)
                .frame(maxHeight: Theme.layout.projectPickerMaxHeight)
            }

            HStack(spacing: Theme.spacing.s12) {
                Button("Choose Folder…") { chooseFolder() }
                    .buttonStyle(.bordered)
                if let sel = selection {
                    Button("Open") {
                        open(URL(fileURLWithPath: sel.path), resumeSessionID: nil)
                    }
                    .buttonStyle(.borderedProminent)
                    .keyboardShortcut(.return)
                    if let last = sel.lastSessionID {
                        Button("Resume Last Session") {
                            open(URL(fileURLWithPath: sel.path), resumeSessionID: last)
                        }
                    }
                }
            }
            .padding(.bottom, Theme.spacing.s24)
        }
        .frame(minWidth: Theme.layout.projectPickerMinWidth, minHeight: Theme.layout.projectPickerMinHeight)
        .background(Theme.surface.canvas)
    }

    // MARK: - Private

    private func chooseFolder() {
        if let url = DesktopActions.chooseDirectoryPanel() {
            open(url, resumeSessionID: nil)
        }
    }

    private func open(_ url: URL, resumeSessionID: String?) {
        onOpen(url, resumeSessionID)
    }

    /// Returns `"CLAUDE.md"` or `"AGENTS.md"` if either file is present
    /// in the project root, or `nil` if neither exists.
    private func memoryFileBadge(at path: String) -> String? {
        DesktopActions.memoryFileBadge(atProjectPath: path)
    }
}

#if DEBUG
#Preview("Project picker – Light") {
    ProjectPickerView(recent: PreviewFixtures.recentProjects) { _, _ in }
        .frame(width: 480, height: 420)
        .preferredColorScheme(.light)
}

#Preview("Project picker – Dark") {
    ProjectPickerView(recent: PreviewFixtures.recentProjects) { _, _ in }
        .frame(width: 480, height: 420)
        .preferredColorScheme(.dark)
}
#endif
