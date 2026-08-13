import Foundation
import AgentCore

extension FolderTreeViewModel {
    func refresh() {
        if isPreviewOnlyListing, let path = selectedRelativePath {
            refreshPreviewOnly(relativePath: path)
            return
        }
        let preservedSearch = searchText
        let preservedFilter = extensionFilter
        let preservedSelection = selectedRelativePath
        let preservedPreview = previewedRelativePath
        let preservedExpanded = expandedPaths
        scanTask?.cancel()
        isLoading = true
        lastError = nil
        let root = root
        let fileSystem = fileSystem
        scanTask = Task { [weak self] in
            do {
                let result = try await FolderFileSupport.offMainActor {
                    try FolderScanner.scanDetailed(root: root, fileSystem: fileSystem)
                }
                guard !Task.isCancelled else { return }
                await MainActor.run {
                    guard let self else { return }
                    self.entries = result.entries
                    self.truncated = result.truncated
                    self.isLoading = false
                    self.lastRefreshedAt = self.clock.now()
                    self.searchText = preservedSearch
                    if let preservedFilter,
                       result.entries.contains(where: { $0.fileExtension == preservedFilter }) {
                        self.extensionFilter = preservedFilter
                    } else if preservedFilter != nil {
                        self.extensionFilter = nil
                    }
                    self.rebuildTree()
                    let presentPaths = Set(result.entries.map(\.relativePath))
                    self.expandedPaths = preservedExpanded.intersection(presentPaths)
                    // Row highlight and preview reconcile independently: a folder
                    // can vanish without touching the open file, and vice versa.
                    if let selected = preservedSelection, presentPaths.contains(selected) {
                        self.selectedRelativePath = selected
                        self.revealPath(selected)
                    } else {
                        self.selectedRelativePath = nil
                    }
                    if let preview = preservedPreview,
                       presentPaths.contains(preview),
                       result.entries.first(where: { $0.relativePath == preview })?
                           .isDirectory == false {
                        self.previewedRelativePath = preview
                        self.loadPreview(for: preview)
                    } else {
                        self.previewedRelativePath = nil
                        self.clearPreview()
                        if result.entries.isEmpty {
                            self.previewMode = .empty
                        }
                    }
                }
            } catch {
                guard !Task.isCancelled else { return }
                await MainActor.run {
                    self?.isLoading = false
                    let message = error.localizedDescription
                    self?.lastError = message
                    if message.localizedCaseInsensitiveContains("permission")
                        || message.localizedCaseInsensitiveContains("denied") {
                        self?.previewMode = .permissionDenied
                        self?.previewText = message
                    }
                }
            }
        }
    }

    /// Loads a single file's metadata + preview without enumerating the folder.
    func refreshPreviewOnly(relativePath: String) {
        scanTask?.cancel()
        isLoading = true
        lastError = nil
        let root = root
        let fileSystem = fileSystem
        scanTask = Task { [weak self] in
            do {
                let entry = try await FolderFileSupport.offMainActor {
                    try FolderFileSupport.makeEntry(
                        relativePath: relativePath,
                        root: root,
                        fileSystem: fileSystem
                    )
                }
                guard !Task.isCancelled else { return }
                await MainActor.run {
                    guard let self else { return }
                    self.entries = [entry]
                    self.truncated = false
                    self.isLoading = false
                    self.lastRefreshedAt = self.clock.now()
                    self.rebuildTree()
                    self.selectedRelativePath = relativePath
                    if entry.isDirectory {
                        self.previewedRelativePath = nil
                        self.clearPreview()
                        self.previewMode = .error
                        self.previewText = "Pinned path is a folder."
                        self.previewTitle = entry.name
                    } else {
                        self.previewedRelativePath = relativePath
                        self.loadPreview(for: relativePath)
                    }
                }
            } catch {
                guard !Task.isCancelled else { return }
                await MainActor.run {
                    guard let self else { return }
                    self.isLoading = false
                    let message = error.localizedDescription
                    self.lastError = message
                    self.entries = []
                    self.treeRoots = []
                    self.previewTitle = URL(fileURLWithPath: relativePath).lastPathComponent
                    if message.localizedCaseInsensitiveContains("permission")
                        || message.localizedCaseInsensitiveContains("denied") {
                        self.previewMode = .permissionDenied
                    } else {
                        self.previewMode = .error
                    }
                    self.previewText = message
                }
            }
        }
    }

    func startWatching() {
        let watcher = FSEventsWatcher(
            workspace: root,
            debounce: 0.25,
            ignoredPrefixes: [".git/", ".codemixer/", "node_modules/", ".build/"]
        )
        self.watcher = watcher
        watchTask = Task { [weak self] in
            do {
                try await watcher.start()
                for await _ in watcher.events {
                    guard let self else { return }
                    try? await Task.sleep(for: FolderBrowserLimits.scanDebounce)
                    guard !Task.isCancelled else { return }
                    await MainActor.run { self.refresh() }
                }
            } catch {
                // Watcher failures leave manual refresh available.
            }
        }
    }
}
