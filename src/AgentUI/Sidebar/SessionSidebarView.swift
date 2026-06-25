import SwiftUI
import AppKit
import AgentCore

/// The session navigator: a calm, collapsible rail listing the loaded
/// workspace's projects and, under each, its resumable sessions in recent-first
/// order (visual-style §12 "Session Navigator").
///
/// Type-first, no competing boxes: a single `surface.panel` background, a
/// hairline trailing divider, hairline group separators. Selection is a soft
/// accent wash (not a heavy fill). Row actions are hover/focus-revealed via
/// `IntentReveal` and also exposed as right-click context menus + Voice Control
/// actions, so mouse, keyboard, voice, and remote reach the same behavior.
///
/// Transport-neutral: when the active agent has no resumable-session concept
/// (`model.supportsResumableSessions == false`) projects show **New Chat only**
/// and no session rows; an empty list is a first-class empty state, not an error.
public struct SessionSidebarView: View {
    @Bindable public var model: EngineViewModel
    @Binding public var focusMode: Bool

    @State private var searchText: String = ""
    @State private var expandedProjects: Set<String> = []
    @State private var newProjectName: String = ""
    @State private var showNewProjectPrompt = false
    @State private var showFolderPicker = false
    @State private var renameTargetPath: String?
    @State private var renameText: String = ""
    @State private var showRenamePrompt = false
    @State private var hoveredProjectPath: String?

    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    public init(model: EngineViewModel, focusMode: Binding<Bool> = .constant(false)) {
        self.model = model
        self._focusMode = focusMode
    }

    public var body: some View {
        Group {
            if focusMode {
                iconRail
            } else {
                fullNavigator
            }
        }
        .background(Theme.surface.panel)
        .overlay(alignment: .trailing) {
            Rectangle()
                .fill(Theme.surface.divider)
                .frame(width: Theme.stroke.hairline)
        }
        .onAppear(perform: expandCurrentProject)
        .onChange(of: model.workspace?.path) { _, _ in expandCurrentProject() }
        .onChange(of: model.projects.map(\.path)) { _, _ in expandCurrentProject() }
        .toolbar {
            ToolbarItemGroup(placement: .navigation) {
                projectMenu
                Button {
                    model.newChat(in: model.workspace?.path ?? "")
                } label: {
                    Image(systemName: "square.and.pencil")
                        .imageScale(.medium)
                }
                .help("New chat")
                .accessibilityLabel("New chat")
            }
        }
        .alert("New Project", isPresented: $showNewProjectPrompt) {
            TextField("Project name", text: $newProjectName)
                .accessibilityLabel("Project name")
            Button("Create") { createProject() }
            Button("Cancel", role: .cancel) { newProjectName = "" }
        } message: {
            Text("Creates a subfolder in the current workspace.")
        }
        .fileImporter(
            isPresented: $showFolderPicker,
            allowedContentTypes: [.folder]
        ) { result in
            guard case .success(let url) = result else { return }
            model.addExistingProject(url: url)
        }
        .animation(Theme.motion.resolve(Theme.motion.changing, reduceMotion: reduceMotion),
                   value: focusMode)
    }

    private var fullNavigator: some View {
        VStack(alignment: .leading, spacing: 0) {
            if model.supportsResumableSessions {
                searchField
            }
            projectList
        }
        .alert("Rename Project", isPresented: $showRenamePrompt) {
            TextField("Display name", text: $renameText)
                .accessibilityLabel("Project display name")
            Button("Rename") { commitRename() }
            Button("Cancel", role: .cancel) { renameTargetPath = nil; renameText = "" }
        } message: {
            Text("Changes the label shown here. The folder on disk is unchanged.")
        }
    }

    // MARK: - Icon rail (focus mode)

    private var iconRail: some View {
        VStack(spacing: Theme.spacing.s12) {
            Button { model.newChat(in: model.workspace?.path ?? "") } label: {
                Image(systemName: "square.and.pencil").imageScale(.medium)
            }
            .buttonStyle(.plain)
            .foregroundStyle(Theme.text.secondary)
            .help("New chat")
            .accessibilityLabel("New chat")

            Divider().overlay(Theme.surface.divider).padding(.horizontal, Theme.spacing.s8)

            ScrollView {
                VStack(spacing: Theme.spacing.s8) {
                    ForEach(model.projects) { project in
                        railProjectButton(project)
                    }
                }
                .padding(.top, Theme.spacing.s4)
            }
            .scrollContentBackground(.hidden)

            Spacer(minLength: 0)

            Button { focusMode = false } label: {
                Image(systemName: "arrow.left.to.line.compact").imageScale(.medium)
            }
            .buttonStyle(.plain)
            .foregroundStyle(Theme.text.secondary)
            .help("Expand navigator")
            .accessibilityLabel("Expand navigator")
        }
        .padding(.vertical, Theme.spacing.s12)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
    }

    private func railProjectButton(_ project: WorkspaceProjectsStore.ProjectRef) -> some View {
        let isCurrent = model.workspace?.path == project.path
        return Button { model.newChat(in: project.path) } label: {
            Image(systemName: "folder")
                .accessibilityHidden(true)
                .imageScale(.medium)
                .foregroundStyle(isCurrent ? Theme.text.primary : Theme.text.tertiary)
                .frame(width: Theme.spacing.s32, height: Theme.spacing.s32)
                .background(
                    RoundedRectangle(cornerRadius: Theme.corner.small, style: .continuous)
                        .fill(isCurrent ? Theme.surface.bubbleUser : Color.clear)
                )
        }
        .buttonStyle(.plain)
        .help("New chat in \(project.displayName)")
        .accessibilityLabel("New chat in \(project.displayName)")
        .accessibilityAddTraits(isCurrent ? [.isSelected] : [])
    }

    private var searchField: some View {
        HStack(spacing: Theme.spacing.s8) {
            Image(systemName: "magnifyingglass")
                .foregroundStyle(Theme.text.tertiary)
                .imageScale(.small)
            TextField("Search sessions", text: $searchText)
                .textFieldStyle(.plain)
                .font(Theme.typography.caption)
                .accessibilityLabel("Search sessions")
        }
        .padding(.horizontal, Theme.spacing.s12)
        .padding(.vertical, Theme.spacing.s8)
    }

    @ViewBuilder
    private var projectMenu: some View {
        Menu {
            Button("New Project…") {
                newProjectName = ""
                showNewProjectPrompt = true
            }
            Button("Add Existing Project…") { showFolderPicker = true }
        } label: {
            Image(systemName: "folder.badge.plus")
                .imageScale(.medium)
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        .fixedSize()
        .help("Add a project")
        .accessibilityLabel("Add a project")
    }

    // MARK: - Project list

    private var projectList: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: Theme.spacing.s4) {
                ForEach(model.projects) { project in
                    projectSection(project)
                }
            }
            .padding(.horizontal, Theme.spacing.s8)
            .padding(.vertical, Theme.spacing.s8)
        }
        .scrollContentBackground(.hidden)
    }

    @ViewBuilder
    private func projectSection(_ project: WorkspaceProjectsStore.ProjectRef) -> some View {
        let isExpanded = expandedProjects.contains(project.path)
        VStack(alignment: .leading, spacing: Theme.spacing.s4) {
            projectRow(project, isExpanded: isExpanded)
            if isExpanded && model.supportsResumableSessions {
                sessionRows(for: project)
            }
        }
        .padding(.top, Theme.spacing.s4)
    }

    private func projectRow(_ project: WorkspaceProjectsStore.ProjectRef,
                            isExpanded: Bool) -> some View {
        let isHovering = hoveredProjectPath == project.path
        return HStack(spacing: Theme.spacing.s8) {
            Text(project.displayName)
                .font(Theme.typography.caption)
                .fontWeight(.semibold)
                .foregroundStyle(Theme.text.secondary)
                .lineLimit(1)
            Spacer(minLength: 0)
            Image(systemName: isExpanded ? "chevron.down" : "chevron.right")
                .font(Theme.typography.iconSmall)
                .foregroundStyle(Theme.text.tertiary)
                .opacity(isHovering ? 1 : 0)
                .accessibilityHidden(true)
        }
        .contentShape(Rectangle())
        .padding(.top, Theme.spacing.s8)
        .padding(.bottom, Theme.spacing.s4)
        .padding(.horizontal, Theme.spacing.s8)
        .onTapGesture { toggle(project) }
        .accessibilityElement(children: .combine)
        .accessibilityLabel("Project \(project.displayName)")
        .accessibilityHint(isExpanded ? "Expanded" : "Collapsed")
        .onHover { hovering in
            hoveredProjectPath = hovering ? project.path : nil
        }
        .contextMenu {
            Button("New Chat") { model.newChat(in: project.path) }
            Button("Reveal in Finder") { revealInFinder(project.path) }
            Divider()
            Button("Rename…") { beginRename(project) }
            if project.path != model.workspace?.path {
                Button("Remove from Navigator", role: .destructive) {
                    model.removeProject(path: project.path)
                }
            }
        }
    }

    @ViewBuilder
    private func sessionRows(for project: WorkspaceProjectsStore.ProjectRef) -> some View {
        if model.loadingProjectPaths.contains(project.path) {
            skeletonRows
        } else {
            let sessions = filteredSessions(for: project.path)
            if sessions.isEmpty {
                Text("No prior sessions. Start a new one.")
                    .font(Theme.typography.caption)
                    .foregroundStyle(Theme.text.tertiary)
                    .padding(.horizontal, Theme.spacing.s8)
                    .padding(.vertical, Theme.spacing.s4)
            } else {
                ForEach(sessions) { session in
                    sessionRow(session, projectPath: project.path)
                }
            }
        }
    }

    private func sessionRow(_ session: SessionSummary, projectPath: String) -> some View {
        let isCurrent = model.isCurrentSession(projectPath: projectPath, sessionID: session.id)
        return Button {
            model.openSession(projectPath: projectPath, id: session.id)
        } label: {
            HStack(spacing: Theme.spacing.s8) {
                if isCurrent {
                    Circle()
                        .fill(Theme.signal.success)
                        .frame(width: 6, height: 6)
                        .accessibilityHidden(true)
                }
                VStack(alignment: .leading, spacing: Theme.spacing.s4) {
                    Text(session.title)
                        .font(Theme.typography.body)
                        .foregroundStyle(isCurrent ? Theme.text.primary : Theme.text.secondary)
                        .lineLimit(1)
                }
                Spacer(minLength: 0)
            }
            .contentShape(Rectangle())
            .padding(.vertical, Theme.spacing.s4)
            .padding(.horizontal, Theme.spacing.s8)
            .background(selectionWash(isCurrent: isCurrent))
        }
        .buttonStyle(.plain)
        .accessibilityElement(children: .combine)
        .accessibilityLabel("Session \(session.title)")
        .accessibilityAddTraits(isCurrent ? [.isSelected] : [])
        .contextMenu {
            Button("Open") { model.openSession(projectPath: projectPath, id: session.id) }
        }
    }

    @ViewBuilder
    private func selectionWash(isCurrent: Bool) -> some View {
        if isCurrent {
            RoundedRectangle(cornerRadius: Theme.corner.small, style: .continuous)
                .fill(Theme.surface.bubbleUser)
        } else {
            Color.clear
        }
    }

    private var skeletonRows: some View {
        VStack(alignment: .leading, spacing: Theme.spacing.s8) {
            ForEach(0..<3, id: \.self) { _ in
                RoundedRectangle(cornerRadius: Theme.corner.small)
                    .fill(Theme.surface.bubble)
                    .frame(height: Theme.spacing.s24)
            }
        }
        .padding(.horizontal, Theme.spacing.s8)
        .padding(.vertical, Theme.spacing.s4)
        .redacted(reason: .placeholder)
        .accessibilityLabel("Loading sessions")
    }

    // MARK: - Helpers

    private func expandCurrentProject() {
        guard let path = model.workspace?.path else { return }
        expandedProjects.insert(path)
        if model.supportsResumableSessions,
           model.sessionsByProject[path] == nil {
            model.loadSessions(for: path)
        }
    }

    private func toggle(_ project: WorkspaceProjectsStore.ProjectRef) {
        let animation = Theme.motion.resolve(Theme.motion.changing, reduceMotion: reduceMotion)
        withAnimation(animation) {
            if expandedProjects.contains(project.path) {
                expandedProjects.remove(project.path)
            } else {
                expandedProjects.insert(project.path)
                if model.sessionsByProject[project.path] == nil {
                    model.loadSessions(for: project.path)
                }
            }
        }
    }

    private func filteredSessions(for projectPath: String) -> [SessionSummary] {
        let all = model.sessionsByProject[projectPath] ?? []
        guard !searchText.isEmpty else { return all }
        return all.filter { $0.title.localizedCaseInsensitiveContains(searchText) }
    }

    private func beginRename(_ project: WorkspaceProjectsStore.ProjectRef) {
        renameTargetPath = project.path
        renameText = project.displayName
        showRenamePrompt = true
    }

    private func createProject() {
        let name = newProjectName.trimmingCharacters(in: .whitespacesAndNewlines)
        newProjectName = ""
        guard !name.isEmpty else { return }
        model.createProject(name: name)
    }

    private func commitRename() {
        guard let path = renameTargetPath else { return }
        let name = renameText.trimmingCharacters(in: .whitespacesAndNewlines)
        renameTargetPath = nil
        renameText = ""
        guard !name.isEmpty else { return }
        model.renameProject(path: path, newName: name)
    }

    private func revealInFinder(_ path: String) {
        DesktopActions.revealInFinder(URL(fileURLWithPath: path))
    }
}

#if DEBUG
#Preview("Sidebar – Light") {
    SessionSidebarView(model: .preview)
        .frame(width: Theme.layout.sessionSidebarIdealWidth, height: 480)
        .preferredColorScheme(.light)
}

#Preview("Sidebar – Dark") {
    SessionSidebarView(model: .preview)
        .frame(width: Theme.layout.sessionSidebarIdealWidth, height: 480)
        .preferredColorScheme(.dark)
}

#Preview("Sidebar – Compact") {
    SessionSidebarView(model: .preview)
        .frame(width: Theme.layout.sessionSidebarMinWidth, height: 320)
}
#endif
