import SwiftUI
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
                Button {
                    model.newChatInCurrentProject()
                } label: {
                    Image(systemName: "square.and.pencil")
                        .imageScale(.medium)
                }
                .help("New chat in current project")
                .accessibilityLabel("New chat in current project")
                .disabled(model.workspace == nil || model.showsFolderBrowser)
            }
        }
        .sheet(isPresented: $showRenamePrompt) {
            RenameProjectSheet(
                name: $renameText,
                onCancel: cancelRename,
                onRename: commitRename
            )
        }
        .animation(Theme.motion.resolve(Theme.motion.changing, reduceMotion: reduceMotion),
                   value: focusMode)
    }

    private var fullNavigator: some View {
        VStack(alignment: .leading, spacing: 0) {
            if model.hasResumableSessionProjects {
                searchField
            }
            projectList
        }
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
        let isFolder = model.isFolderProject(project)
        VStack(alignment: .leading, spacing: Theme.spacing.s4) {
            projectRow(project, isExpanded: isExpanded)
            if isFolder {
                folderShortcutRows(for: project)
            } else if isExpanded {
                if model.supportsOverviewDashboard(forProjectPath: project.path) {
                    overviewRow(for: project)
                }
                if model.supportsResumableSessions(for: project) {
                    sessionRows(for: project)
                }
            }
        }
        .padding(.top, Theme.spacing.s4)
    }

    private func projectRow(_ project: WorkspaceProjectsStore.ProjectRef,
                            isExpanded: Bool) -> some View {
        let isHovering = hoveredProjectPath == project.path
        let isCurrent = model.workspace?.path == project.path
        let attention = model.isFolderProject(project) ? 0 : attentionSessionCount(for: project.path)
        let isFolder = model.isFolderProject(project)
        return HStack(spacing: Theme.spacing.s8) {
            Text(project.displayName)
                .font(Theme.typography.body)
                .fontWeight(.bold)
                .foregroundStyle(isCurrent ? Theme.text.primary : Theme.text.secondary)
                .lineLimit(1)
            if shouldShowProjectTypeLabel(for: project) {
                projectTypeLabel(project.projectType, isCurrent: isCurrent)
            }
            Spacer(minLength: 0)
            if attention > 0 {
                attentionCountBadge(attention)
            }
            if !isFolder {
                Image(systemName: isExpanded ? "chevron.down" : "chevron.right")
                    .font(Theme.typography.iconSmall)
                    .foregroundStyle(Theme.text.tertiary)
                    .opacity(isHovering || isCurrent ? 1 : 0)
                    .accessibilityHidden(true)
            }
        }
        .contentShape(Rectangle())
        .padding(.top, Theme.spacing.s8)
        .padding(.bottom, Theme.spacing.s4)
        .padding(.horizontal, Theme.spacing.s8)
        .overlay(alignment: .leading) { currentProjectRail(isCurrent: isCurrent) }
        .onTapGesture { handleProjectTap(project) }
        .accessibilityElement(children: .combine)
        .accessibilityLabel(
            attention > 0
                ? "Project \(project.displayName), \(attention) sessions need attention"
                : "Project \(project.displayName)"
        )
        .accessibilityHint(isFolder
                           ? "Open folder view"
                           : (isExpanded ? "Collapse project" : "Expand project"))
        .accessibilityAddTraits(isCurrent ? [.isSelected] : [])
        .onHover { hovering in
            hoveredProjectPath = hovering ? project.path : nil
        }
        .contextMenu {
            if !isFolder {
                Button("New Chat") { model.newChat(in: project.path) }
            }
            Button("Reveal in Finder") { revealInFinder(project.path) }
            if model.isCustomACPProject(project) {
                Button("Restart ACP CLI") {
                    model.restartCustomACPCLI(projectPath: project.path)
                }
                .accessibilityLabel("Restart ACP CLI")
            }
            Divider()
            if canRenameProject(project) {
                Button("Rename…") { beginRename(project) }
            }
            if project.path != model.workspace?.path {
                Button("Remove from Navigator", role: .destructive) {
                    model.removeProject(path: project.path)
                }
            }
        }
    }

    private func shouldShowProjectTypeLabel(for project: WorkspaceProjectsStore.ProjectRef) -> Bool {
        project.projectType.showsSidebarTypeCapsule
    }

    /// A slim "you are here" rail in the leading gutter of the current project,
    /// echoing the conversation turn spine. Calmer than a full-row wash, and it
    /// stays distinct from the child chat selection (which uses `selectionWash`).
    @ViewBuilder
    private func currentProjectRail(isCurrent: Bool) -> some View {
        if isCurrent {
            Capsule(style: .continuous)
                .fill(Theme.accent.solid)
                .frame(width: Theme.stroke.focus, height: Theme.spacing.s16)
                .offset(x: -Theme.spacing.s4)
                .accessibilityHidden(true)
        }
    }

    private func projectTypeLabel(_ projectType: ProjectType, isCurrent: Bool) -> some View {
        Text(projectType.shortLabel)
            .font(Theme.typography.caption)
            .foregroundStyle(isCurrent ? Theme.text.primary : Theme.text.tertiary)
            .padding(.horizontal, Theme.spacing.s4)
            .padding(.vertical, Theme.corner.hairline)
            .background(
                isCurrent ? Theme.surface.bubbleUser : Theme.surface.bubble.opacity(Theme.opacity.faint),
                in: .capsule
            )
    }

    @ViewBuilder
    private func folderShortcutRows(for project: WorkspaceProjectsStore.ProjectRef) -> some View {
        let shortcuts = model.folderSidebarShortcuts(for: project)
        ForEach(shortcuts) { shortcut in
            folderShortcutRow(shortcut, project: project)
        }
    }

    private func folderShortcutRow(_ shortcut: FolderSidebarShortcut,
                                   project: WorkspaceProjectsStore.ProjectRef) -> some View {
        let isCurrent = model.workspace?.path == project.path
            && model.showsFolderBrowser
            && model.activeFolderSelectionRelativePath == shortcut.relativePath
        return Button {
            model.openFolderShortcut(projectPath: project.path, relativePath: shortcut.relativePath)
        } label: {
            HStack(spacing: Theme.spacing.s8) {
                if isCurrent {
                    Circle()
                        .fill(Theme.signal.success)
                        .frame(width: 6, height: 6)
                        .accessibilityHidden(true)
                }
                Image(systemName: "doc")
                    .imageScale(.small)
                    .foregroundStyle(Theme.text.tertiary)
                    .accessibilityHidden(true)
                Text(shortcut.displayName)
                    .font(Theme.typography.body)
                    .foregroundStyle(isCurrent ? Theme.text.primary : Theme.text.secondary)
                    .lineLimit(1)
                Spacer(minLength: 0)
            }
            .contentShape(Rectangle())
            .padding(.vertical, Theme.spacing.s4)
            .padding(.leading, Theme.spacing.s16)
            .padding(.trailing, Theme.spacing.s8)
            .background(selectionWash(isCurrent: isCurrent))
        }
        .buttonStyle(.plain)
        .help(shortcut.relativePath)
        .accessibilityLabel(shortcut.relativePath)
        .accessibilityAddTraits(isCurrent ? [.isSelected] : [])
        .contextMenu {
            Button("Open") {
                model.openFolderShortcut(projectPath: project.path, relativePath: shortcut.relativePath)
            }
            if project.projectType.folderKind?.supportsPinnedSidebarEntries == true {
                Button("Unpin from Sidebar") {
                    model.unpinFolderPath(shortcut.relativePath, in: project.path)
                }
                Button("Move Up") {
                    model.movePinnedFolderPath(shortcut.relativePath, in: project.path, direction: -1)
                }
                Button("Move Down") {
                    model.movePinnedFolderPath(shortcut.relativePath, in: project.path, direction: 1)
                }
            }
            Button("Reveal in Finder") {
                let url = URL(fileURLWithPath: project.path)
                    .appendingPathComponent(shortcut.relativePath)
                revealInFinder(url.path)
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
                    .padding(.leading, Theme.spacing.s16)
                    .padding(.trailing, Theme.spacing.s8)
                    .padding(.vertical, Theme.spacing.s4)
            } else {
                ForEach(sessions) { session in
                    sessionRow(session, projectPath: project.path)
                }
            }
        }
    }

    private func overviewRow(for project: WorkspaceProjectsStore.ProjectRef) -> some View {
        let title = overviewTitle(for: project)
        let isCurrent = model.workspace?.path == project.path && model.showsOverviewDashboard
        let attention = attentionSessionCount(for: project.path)
        return Button {
            model.openOverview(projectPath: project.path)
        } label: {
            HStack(spacing: Theme.spacing.s8) {
                Image(systemName: "rectangle.grid.2x2")
                    .imageScale(.small)
                    .foregroundStyle(isCurrent ? Theme.text.primary : Theme.text.secondary)
                    .accessibilityHidden(true)
                Text(title)
                    .font(Theme.typography.body)
                    .foregroundStyle(isCurrent ? Theme.text.primary : Theme.text.secondary)
                    .lineLimit(1)
                Spacer(minLength: 0)
                if attention > 0 {
                    attentionCountBadge(attention)
                }
            }
            .contentShape(Rectangle())
            .padding(.vertical, Theme.spacing.s4)
            .padding(.leading, Theme.spacing.s16)
            .padding(.trailing, Theme.spacing.s8)
            .background(selectionWash(isCurrent: isCurrent))
        }
        .buttonStyle(.plain)
        .accessibilityElement(children: .combine)
        .accessibilityLabel(
            attention > 0
                ? "\(title), \(attention) sessions need attention"
                : title
        )
        .accessibilityAddTraits(isCurrent ? [.isSelected] : [])
        .contextMenu {
            Button("Open") { model.openOverview(projectPath: project.path) }
        }
    }

    private func attentionCountBadge(_ count: Int) -> some View {
        Text("\(count)")
            .font(Theme.typography.caption)
            .foregroundStyle(Theme.text.primary)
            .padding(.horizontal, Theme.spacing.s4)
            .padding(.vertical, Theme.corner.hairline)
            .background(Theme.signal.warning.opacity(0.35), in: Capsule())
            .accessibilityLabel("\(count) sessions need attention")
    }

    /// Non-private: shared with the icon-rail badge in `+IconRail.swift`.
    func attentionSessionCount(for projectPath: String) -> Int {
        (model.sessionsByProject[projectPath] ?? [])
            .filter { $0.needsAttention && !$0.isOverview }
            .count
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
                if session.needsAttention {
                    Circle()
                        .fill(Theme.signal.warning)
                        .frame(width: 8, height: 8)
                        .accessibilityLabel("Needs attention")
                }
            }
            .contentShape(Rectangle())
            .padding(.vertical, Theme.spacing.s4)
            .padding(.leading, Theme.spacing.s16)
            .padding(.trailing, Theme.spacing.s8)
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
        .padding(.leading, Theme.spacing.s16)
        .padding(.trailing, Theme.spacing.s8)
        .padding(.vertical, Theme.spacing.s4)
        .redacted(reason: .placeholder)
        .accessibilityLabel("Loading sessions")
    }

    // MARK: - Helpers

    private func expandCurrentProject() {
        guard let path = model.workspace?.path else { return }
        expandedProjects.insert(path)
        if model.supportsResumableSessions(forProjectPath: path) {
            model.loadSessions(for: path)
        }
    }

    /// Project title click: select as current project and expand. Overview-capable
    /// projects (Custom ACP) also select the overview entry. A second click on the
    /// already-current expanded project collapses it. Folder projects always open
    /// the browser and never expand/collapse.
    private func handleProjectTap(_ project: WorkspaceProjectsStore.ProjectRef) {
        if model.isFolderProject(project) {
            model.selectProject(path: project.path)
            return
        }
        let isCurrent = model.workspace?.path == project.path
        let isExpanded = expandedProjects.contains(project.path)
        let isOverviewCapable = model.supportsOverviewDashboard(forProjectPath: project.path)
        let isShowingOverview = isCurrent && model.showsOverviewDashboard
        let animation = Theme.motion.resolve(Theme.motion.changing, reduceMotion: reduceMotion)

        // Overview-capable: title click makes the project current and selects
        // Overview. Collapse only when Overview is already selected and expanded.
        if isOverviewCapable {
            withAnimation(animation) {
                if isShowingOverview && isExpanded {
                    expandedProjects.remove(project.path)
                } else {
                    expandedProjects.insert(project.path)
                    if model.supportsResumableSessions(for: project) || isOverviewCapable {
                        model.loadSessions(for: project.path)
                    }
                }
            }
            if !(isShowingOverview && isExpanded) {
                model.selectProject(path: project.path)
            }
            return
        }

        withAnimation(animation) {
            if isExpanded {
                expandedProjects.remove(project.path)
            } else {
                expandedProjects.insert(project.path)
                if model.supportsResumableSessions(for: project) {
                    model.loadSessions(for: project.path)
                }
            }
        }
        if !isCurrent {
            model.selectProject(path: project.path)
        }
    }

    private func filteredSessions(for projectPath: String) -> [SessionSummary] {
        let chats = SessionNavigatorFiltering.chatSessions(
            from: model.sessionsByProject[projectPath] ?? [],
            dashboardTitle: model.dashboardTitle
        )
        guard !searchText.isEmpty else { return chats }
        return chats.filter { $0.title.localizedCaseInsensitiveContains(searchText) }
    }

    private func overviewTitle(for project: WorkspaceProjectsStore.ProjectRef) -> String {
        if model.workspace?.path == project.path,
           let title = model.dashboardTitle,
           !title.isEmpty {
            return title
        }
        return project.displayName
    }

    private func beginRename(_ project: WorkspaceProjectsStore.ProjectRef) {
        renameTargetPath = project.path
        renameText = project.displayName
        showRenamePrompt = true
    }

    private func canRenameProject(_ project: WorkspaceProjectsStore.ProjectRef) -> Bool {
        project.path != model.workspaceRoot?.path
            && model.activity == .idle
    }

    private func commitRename() {
        guard let path = renameTargetPath else { return }
        let name = renameText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty else { return }
        showRenamePrompt = false
        renameTargetPath = nil
        renameText = ""
        model.renameProject(path: path, newName: name)
    }

    private func cancelRename() {
        showRenamePrompt = false
        renameTargetPath = nil
        renameText = ""
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
