import Foundation
import AgentCore

extension FolderTreeViewModel {
    /// Filtered tree shown in the outline. When a filter is active, matching
    /// files keep their ancestor directories and those ancestors appear expanded
    /// without mutating `expandedPaths`.
    var visibleTreeRoots: [FolderTreeNode] {
        guard hasActiveFilter else { return treeRoots }
        let query = searchText.trimmingCharacters(in: .whitespacesAndNewlines)
        let ext = extensionFilter
        return FolderTreeBuilder.pruned(treeRoots) { entry in
            if let ext, entry.fileExtension != ext { return false }
            guard !query.isEmpty else { return true }
            return entry.name.localizedCaseInsensitiveContains(query)
                || entry.relativePath.localizedCaseInsensitiveContains(query)
                || entry.fileExtension.localizedCaseInsensitiveContains(query)
        }
    }

    /// Paths that should render as expanded in the outline.
    var effectiveExpandedPaths: Set<String> {
        guard hasActiveFilter else { return expandedPaths }
        var paths = expandedPaths
        for root in visibleTreeRoots {
            collectDirectoryPaths(in: root, into: &paths)
        }
        return paths
    }

    var filterMatchCount: Int {
        guard hasActiveFilter else { return fileCount }
        return countFiles(in: visibleTreeRoots)
    }

    func rebuildTree() {
        treeRoots = FolderTreeBuilder.build(entries: entries)
    }

    func isExpanded(_ relativePath: String) -> Bool {
        effectiveExpandedPaths.contains(relativePath)
    }

    func setExpanded(_ relativePath: String, expanded: Bool) {
        if expanded {
            expandedPaths.insert(relativePath)
        } else {
            expandedPaths.remove(relativePath)
        }
    }

    func toggleExpanded(_ relativePath: String) {
        setExpanded(relativePath, expanded: !expandedPaths.contains(relativePath))
    }

    func expandAll() {
        var paths = Set<String>()
        for root in treeRoots {
            collectDirectoryPaths(in: root, into: &paths)
        }
        expandedPaths = paths
    }

    func collapseAll() {
        expandedPaths = []
    }

    func select(_ relativePath: String?) {
        selectedRelativePath = relativePath
        updatePreviewForSelection()
    }

    /// A click on a row. Selecting a folder is not what the user is asking for —
    /// they want to see what is inside — so activating a directory toggles it.
    ///
    /// A double click arrives as two taps. Toggling on both would leave the
    /// folder exactly as it started, so a repeat activation of the same row
    /// inside `rowActivationCoalesceWindow` is absorbed.
    func activate(_ relativePath: String) {
        if selectedRelativePath != relativePath {
            select(relativePath)
        }
        guard entries.first(where: { $0.relativePath == relativePath })?.isDirectory == true else {
            return
        }
        let now = clock.now()
        let isDoubleClickTail = lastActivatedPath == relativePath
            && (lastActivatedAt.map {
                now.timeIntervalSince($0) < FolderBrowserLimits.rowActivationCoalesceWindow
            } ?? false)
        lastActivatedPath = relativePath
        lastActivatedAt = now
        guard !isDoubleClickTail else { return }
        toggleExpanded(relativePath)
    }

    func clearSearchAndFilters() {
        searchText = ""
        extensionFilter = nil
        showFilters = false
    }

    func handleEscape() -> Bool {
        if !searchText.isEmpty || extensionFilter != nil || showFilters {
            clearSearchAndFilters()
            return true
        }
        if selectedRelativePath != nil {
            select(nil)
            return true
        }
        return false
    }

    /// Expands ancestors so `relativePath` is visible after selection.
    func revealPath(_ relativePath: String) {
        var parent = FolderFileSupport.parentRelativePath(of: relativePath)
        while !parent.isEmpty {
            expandedPaths.insert(parent)
            parent = FolderFileSupport.parentRelativePath(of: parent)
        }
    }

    /// Left-arrow target: the enclosing directory, or `nil` at the root.
    func parentOfSelection() -> String? {
        guard let selectedRelativePath else { return nil }
        let parent = FolderFileSupport.parentRelativePath(of: selectedRelativePath)
        return parent.isEmpty ? nil : parent
    }

    private func updatePreviewForSelection() {
        guard let selectedRelativePath else {
            clearPreview()
            return
        }
        if let entry = selectedEntry, entry.isDirectory {
            clearPreview()
            previewTitle = entry.name
            return
        }
        loadPreview(for: selectedRelativePath)
    }

    private func collectDirectoryPaths(in node: FolderTreeNode, into set: inout Set<String>) {
        if node.entry.isDirectory {
            set.insert(node.entry.relativePath)
        }
        for child in node.children {
            collectDirectoryPaths(in: child, into: &set)
        }
    }

    private func countFiles(in nodes: [FolderTreeNode]) -> Int {
        nodes.reduce(0) { partial, node in
            if node.entry.isDirectory {
                return partial + countFiles(in: node.children)
            }
            return partial + 1
        }
    }

}
