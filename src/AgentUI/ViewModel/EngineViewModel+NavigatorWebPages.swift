import Foundation
import AgentCore
import AgentProtocol

extension EngineViewModel {
    public func isWebPagesProject(_ project: WorkspaceProjectsStore.ProjectRef) -> Bool {
        project.projectType.isWebPagesBacked
    }

    public func openWebPagesProject(_ project: WorkspaceProjectsStore.ProjectRef,
                                    pageID: UUID? = nil) {
        guard project.projectType.isWebPagesBacked else { return }
        bindActiveProject(project)
        sessionID = nil
        clearConversationState()
        clearAllPendingPermissions()
        clearSessionActivation()
        status = .idle
        activity = .idle
        dashboardURL = nil
        dashboardTitle = nil
        availableModels = []
        availableAgentModes = []
        selectedAgentModeID = ""
        slashCommands = []
        supportsResumableSessions = false
        refreshWebPages(for: project)
        let pages = webPages(for: project)
        let resolvedID = pageID ?? pages.first?.id
        detailPane = .webPage(pageID: resolvedID)
    }

    public func openWebPage(projectPath: String, pageID: UUID) {
        guard let project = projectRef(at: projectPath),
              project.projectType.isWebPagesBacked else { return }
        openWebPagesProject(project, pageID: pageID)
    }

    public func webPages(for project: WorkspaceProjectsStore.ProjectRef) -> [WebPageEntry] {
        webPagesByProject[project.path]
            ?? ProjectLocalStateStore.load(
                from: URL(fileURLWithPath: project.path),
                fileSystem: projectLocalFileSystem
            )?.webPages?.pages
            ?? []
    }

    public func webPageSessionStoreIdentifier(for projectPath: String) -> UUID? {
        if let cached = webPageSessionStoreIDsByProject[projectPath] {
            return cached
        }
        return ProjectLocalStateStore.load(
            from: URL(fileURLWithPath: projectPath),
            fileSystem: projectLocalFileSystem
        )?.webPages?.sessionStoreIdentifier
    }

    public func refreshWebPages(for project: WorkspaceProjectsStore.ProjectRef) {
        guard project.projectType.isWebPagesBacked else {
            webPagesByProject.removeValue(forKey: project.path)
            webPageSessionStoreIDsByProject.removeValue(forKey: project.path)
            return
        }
        let root = URL(fileURLWithPath: project.path)
        let config = ProjectLocalStateStore.load(from: root, fileSystem: projectLocalFileSystem)?.webPages
        webPagesByProject[project.path] = config?.pages ?? []
        if let id = config?.sessionStoreIdentifier {
            webPageSessionStoreIDsByProject[project.path] = id
        }
    }

    public func addWebPage(_ entry: WebPageEntry, in projectPath: String) {
        guard let project = projectRef(at: projectPath),
              project.projectType.isWebPagesBacked else { return }
        var pages = webPages(for: project)
        guard pages.count < WebPageEntry.maxPages else {
            diagnostics.append(diagnostic(
                level: .warning,
                message: "At most \(WebPageEntry.maxPages) web pages can be stored in a project."
            ))
            return
        }
        pages.append(entry)
        persistWebPages(pages, in: project)
        if case .webPage(let current) = detailPane, current == nil {
            detailPane = .webPage(pageID: entry.id)
        }
    }

    public func updateWebPage(_ entry: WebPageEntry, in projectPath: String) {
        guard let project = projectRef(at: projectPath),
              project.projectType.isWebPagesBacked else { return }
        var pages = webPages(for: project)
        guard let idx = pages.firstIndex(where: { $0.id == entry.id }) else { return }
        pages[idx] = entry
        persistWebPages(pages, in: project)
        WebPageViewStore.shared.evict(projectPath: projectPath, pageID: entry.id)
        webPageReloadGeneration &+= 1
    }

    public func removeWebPage(pageID: UUID, in projectPath: String) {
        guard let project = projectRef(at: projectPath),
              project.projectType.isWebPagesBacked else { return }
        var pages = webPages(for: project)
        pages.removeAll { $0.id == pageID }
        persistWebPages(pages, in: project)
        WebPageViewStore.shared.evict(projectPath: projectPath, pageID: pageID)
        if case .webPage(let current) = detailPane, current == pageID {
            detailPane = .webPage(pageID: pages.first?.id)
        }
    }

    public func moveWebPage(pageID: UUID, in projectPath: String, direction: Int) {
        guard let project = projectRef(at: projectPath),
              project.projectType.isWebPagesBacked else { return }
        var pages = webPages(for: project)
        guard let idx = pages.firstIndex(where: { $0.id == pageID }) else { return }
        let target = idx + direction
        guard pages.indices.contains(target) else { return }
        pages.swapAt(idx, target)
        persistWebPages(pages, in: project)
    }

    public func clearWebSessionData(projectPath: String) {
        let storeID = webPageSessionStoreIdentifier(for: projectPath)
            ?? ProjectLocalStateStore.load(
                from: URL(fileURLWithPath: projectPath),
                fileSystem: projectLocalFileSystem
            )?.webPages?.sessionStoreIdentifier
        WebPageViewStore.shared.evictAll(projectPath: projectPath)
        if let storeID {
            webSessionDataCleaner(storeID)
        }
        webPageReloadGeneration &+= 1
    }

    private func persistWebPages(_ pages: [WebPageEntry],
                                 in project: WorkspaceProjectsStore.ProjectRef) {
        let root = URL(fileURLWithPath: project.path)
        do {
            let config = try ProjectLocalStateStore.updateWebPages(
                pages,
                in: root,
                fileSystem: projectLocalFileSystem
            )
            webPagesByProject[project.path] = config?.pages ?? []
            if let id = config?.sessionStoreIdentifier {
                webPageSessionStoreIDsByProject[project.path] = id
            }
        } catch {
            recordProjectError(error)
        }
    }
}
