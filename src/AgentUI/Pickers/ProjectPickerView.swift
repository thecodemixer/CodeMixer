import SwiftUI
import AgentCore
import AgentProtocol

/// Project picker shown when the workspace isn't set yet.
///
/// Renders a searchable recent-projects list (read from `SessionStore`) plus a
/// "Choose folder…" button. A CLAUDE.md / AGENTS.md
/// presence chip appears on each project row when the file is detected.
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
                    .accessibilityLabel("Project picker")
                    .font(Theme.typography.heroIcon)
                    .foregroundStyle(Theme.text.tertiary)
                Text("Open a project")
                    .font(Theme.typography.title)
                Text("Codemixer wraps your Claude Code session in this folder.")
                    .font(Theme.typography.caption)
                    .foregroundStyle(Theme.text.secondary)
            }
            .padding(.top, Theme.spacing.s32)

            if recent.isEmpty {
                Text("No recent projects yet.")
                    .foregroundStyle(Theme.text.secondary)
            } else {
                // Search field above the list.
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
                                        // CLAUDE.md / AGENTS.md presence chip.
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
                                Button("Open in new window") {
                                    onOpen(URL(fileURLWithPath: project.path), nil)
                                }
                                if let last = project.lastSessionID {
                                    Button("Resume last session") {
                                        onOpen(URL(fileURLWithPath: project.path), last)
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
                        onOpen(URL(fileURLWithPath: sel.path), nil)
                    }
                    .buttonStyle(.borderedProminent)
                    .keyboardShortcut(.return)
                    if let last = sel.lastSessionID {
                        Button("Resume Last Session") {
                            onOpen(URL(fileURLWithPath: sel.path), last)
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
            onOpen(url, nil)
        }
    }

    /// Returns `"CLAUDE.md"` or `"AGENTS.md"` if either file is present
    /// in the project root, or `nil` if neither exists.
    private func memoryFileBadge(at path: String) -> String? {
        let fm = FileManager.default
        if fm.fileExists(atPath: (path as NSString).appendingPathComponent("CLAUDE.md")) {
            return "CLAUDE.md"
        }
        if fm.fileExists(atPath: (path as NSString).appendingPathComponent("AGENTS.md")) {
            return "AGENTS.md"
        }
        return nil
    }
}
