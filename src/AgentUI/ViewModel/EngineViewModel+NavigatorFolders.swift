import Foundation
import AgentCore
import AgentProtocol

extension EngineViewModel {
    public func openFolderProject(_ project: WorkspaceProjectsStore.ProjectRef,
                                  relativePath: String?,
                                  focusPreview: Bool = false) {
        guard let kind = project.projectType.folderKind else { return }
        endSessionSwitch()
        let target = URL(fileURLWithPath: project.path).standardizedFileURL
        workspace = target
        sessionID = nil
        clearConversationState()
        clearAllPendingPermissions()
        unlockComposerForSessionResume()
        status = .idle
        activity = .idle
        dashboardURL = nil
        dashboardTitle = nil
        availableModels = []
        availableAgentModes = []
        selectedAgentModeID = ""
        slashCommands = []
        supportsResumableSessions = false
        // Preview-only opens are owned by FilePreviewPanelHost — do not seed the
        // folder list's pending selection (avoids a one-frame list+empty-preview flash).
        let previewOnly = focusPreview
            && relativePath != nil
            && kind.showsPreviewOnSelection
        if previewOnly, let relativePath {
            detailPane = .folderPreviewOnly(kind: kind, relativePath: relativePath)
        } else {
            detailPane = .folderBrowser(kind: kind, selectedRelativePath: relativePath, pendingRelativePath: relativePath)
        }
        refreshFolderSidebarShortcuts(for: project)
    }

    /// Keeps the sidebar active-file marker in sync with the folder browser.
    public func setActiveFolderSelection(_ relativePath: String?) {
        switch detailPane {
        case .folderBrowser(let kind, _, let pending):
            detailPane = .folderBrowser(kind: kind, selectedRelativePath: relativePath, pendingRelativePath: pending)
        case .folderPreviewOnly(let kind, _):
            if let relativePath {
                detailPane = .folderPreviewOnly(kind: kind, relativePath: relativePath)
            } else {
                detailPane = .folderBrowser(kind: kind, selectedRelativePath: nil, pendingRelativePath: nil)
            }
        case .conversation, .dashboard:
            break
        }
    }

    /// Leaves preview-only mode and restores the folder file list.
    public func exitFolderPreviewOnly() {
        guard case .folderPreviewOnly(let kind, let relativePath) = detailPane else { return }
        detailPane = .folderBrowser(kind: kind, selectedRelativePath: relativePath, pendingRelativePath: nil)
    }

    /// Open a sidebar shortcut under a folder project.
    public func openFolderShortcut(projectPath: String, relativePath: String) {
        guard let project = projectRef(at: projectPath),
              project.projectType.isFolderBacked else { return }
        openFolderProject(project, relativePath: relativePath, focusPreview: true)
    }

    public func isFolderProject(_ project: WorkspaceProjectsStore.ProjectRef) -> Bool {
        project.projectType.isFolderBacked
    }

    public func folderSidebarShortcuts(for project: WorkspaceProjectsStore.ProjectRef) -> [FolderSidebarShortcut] {
        guard let kind = project.projectType.folderKind else { return [] }
        if kind.showsAutomaticSidebarShortcuts {
            return folderAutomaticShortcutsByProject[project.path] ?? []
        }
        if kind.supportsPinnedSidebarEntries {
            let paths = folderPinnedPathsByProject[project.path]
                ?? ProjectLocalStateStore.load(
                    from: URL(fileURLWithPath: project.path),
                    fileSystem: SystemFileSystem()
                )?.folderView?.pinnedRelativePaths
                ?? []
            return paths.map { FolderSidebarShortcut(relativePath: $0) }
        }
        return []
    }

    public func refreshFolderSidebarShortcuts(for project: WorkspaceProjectsStore.ProjectRef) {
        guard let kind = project.projectType.folderKind else { return }
        let root = URL(fileURLWithPath: project.path)
        if kind.supportsPinnedSidebarEntries {
            let pins = ProjectLocalStateStore.load(from: root, fileSystem: SystemFileSystem())?
                .folderView?.pinnedRelativePaths ?? []
            folderPinnedPathsByProject[project.path] = pins
        } else {
            folderPinnedPathsByProject.removeValue(forKey: project.path)
        }
        if kind.showsAutomaticSidebarShortcuts {
            Task { @MainActor [weak self] in
                await self?.reloadAutomaticLogShortcuts(for: project)
            }
        } else {
            folderAutomaticShortcutsByProject.removeValue(forKey: project.path)
        }
    }

    public func pinFolderPath(_ relativePath: String, in projectPath: String) {
        guard let project = projectRef(at: projectPath),
              let kind = project.projectType.folderKind,
              kind.supportsPinnedSidebarEntries else { return }
        let root = URL(fileURLWithPath: project.path)
        var pins = folderPinnedPathsByProject[project.path]
            ?? ProjectLocalStateStore.load(from: root, fileSystem: SystemFileSystem())?
                .folderView?.pinnedRelativePaths
            ?? []
        guard pins.count < FolderViewState.maxPinnedPaths || pins.contains(relativePath) else {
            diagnostics.append(diagnostic(
                level: .warning,
                message: "At most \(FolderViewState.maxPinnedPaths) files can be pinned in the sidebar."
            ))
            return
        }
        if let existing = pins.firstIndex(of: relativePath) {
            pins.remove(at: existing)
        }
        pins.insert(relativePath, at: 0)
        pins = FolderViewState.normalized(pins)
        do {
            _ = try ProjectLocalStateStore.updatePinnedRelativePaths(
                pins,
                in: root,
                fileSystem: SystemFileSystem()
            )
            folderPinnedPathsByProject[project.path] = pins
        } catch {
            recordProjectError(error)
        }
    }

    public func unpinFolderPath(_ relativePath: String, in projectPath: String) {
        guard let project = projectRef(at: projectPath) else { return }
        let root = URL(fileURLWithPath: project.path)
        var pins = folderPinnedPathsByProject[project.path]
            ?? ProjectLocalStateStore.load(from: root, fileSystem: SystemFileSystem())?
                .folderView?.pinnedRelativePaths
            ?? []
        pins.removeAll { $0 == relativePath }
        do {
            _ = try ProjectLocalStateStore.updatePinnedRelativePaths(
                pins,
                in: root,
                fileSystem: SystemFileSystem()
            )
            folderPinnedPathsByProject[project.path] = pins
        } catch {
            recordProjectError(error)
        }
    }

    public func movePinnedFolderPath(_ relativePath: String,
                                     in projectPath: String,
                                     direction: Int) {
        guard let project = projectRef(at: projectPath) else { return }
        let root = URL(fileURLWithPath: project.path)
        var pins = folderPinnedPathsByProject[project.path]
            ?? ProjectLocalStateStore.load(from: root, fileSystem: SystemFileSystem())?
                .folderView?.pinnedRelativePaths
            ?? []
        guard let idx = pins.firstIndex(of: relativePath) else { return }
        let target = idx + direction
        guard pins.indices.contains(target) else { return }
        pins.swapAt(idx, target)
        do {
            _ = try ProjectLocalStateStore.updatePinnedRelativePaths(
                pins,
                in: root,
                fileSystem: SystemFileSystem()
            )
            folderPinnedPathsByProject[project.path] = pins
        } catch {
            recordProjectError(error)
        }
    }

    /// Leaves the folder browser for the plain conversation surface. A no-op
    /// when the folder browser isn't the active surface (in particular, it
    /// never touches an already-active dashboard).
    func clearFolderBrowserSurface() {
        switch detailPane {
        case .folderBrowser, .folderPreviewOnly:
            detailPane = .conversation
        case .conversation, .dashboard:
            break
        }
    }
    private func reloadAutomaticLogShortcuts(for project: WorkspaceProjectsStore.ProjectRef) async {
        let root = URL(fileURLWithPath: project.path)
        let fs = SystemFileSystem()
        let entries = (try? FolderProjectScanner.scan(
            root: root,
            fileSystem: fs,
            maxEntries: FolderBrowserLimits.maxScanEntries
        )) ?? []
        let logs = entries
            .filter { !$0.isDirectory }
            .sorted { $0.modifiedAt > $1.modifiedAt }
            .prefix(FolderBrowserLimits.automaticLogShortcuts)
            .map { FolderSidebarShortcut(relativePath: $0.relativePath) }
        folderAutomaticShortcutsByProject[project.path] = Array(logs)
    }
}
