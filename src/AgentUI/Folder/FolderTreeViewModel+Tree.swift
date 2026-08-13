import Foundation
import AgentCore

extension FolderTreeViewModel {
    /// Paths that should render as expanded in the outline.
    var effectiveExpandedPaths: Set<String> {
        guard hasActiveFilter else { return expandedPaths }
        return expandedPaths.union(filterExpandedPaths)
    }

    var filterMatchCount: Int {
        guard hasActiveFilter else { return fileCount }
        return countFiles(in: visibleTreeRoots)
    }

    func rebuildTree() {
        treeRoots = FolderTreeBuilder.build(entries: entries)
        rebuildVisibleTree()
    }

    /// Recomputes the filtered outline. Called when the tree or the filter
    /// changes — never from a view body, which is what made this expensive.
    func rebuildVisibleTree() {
        guard hasActiveFilter else {
            visibleTreeRoots = treeRoots
            filterExpandedPaths = []
            return
        }
        let query = searchText.trimmingCharacters(in: .whitespacesAndNewlines)
        let ext = extensionFilter
        let pruned = FolderTreeBuilder.pruned(treeRoots) { entry in
            if let ext, entry.fileExtension != ext { return false }
            guard !query.isEmpty else { return true }
            return entry.name.localizedCaseInsensitiveContains(query)
                || entry.relativePath.localizedCaseInsensitiveContains(query)
                || entry.fileExtension.localizedCaseInsensitiveContains(query)
        }
        var forced = Set<String>()
        for root in pruned {
            collectDirectoryPaths(in: root, into: &forced)
        }
        visibleTreeRoots = pruned
        filterExpandedPaths = forced
    }

    /// Hot path: the outline calls this for every directory row it draws.
    func isExpanded(_ relativePath: String) -> Bool {
        if expandedPaths.contains(relativePath) { return true }
        return hasActiveFilter && filterExpandedPaths.contains(relativePath)
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
        guard selectedRelativePath != relativePath else { return }
        selectedRelativePath = relativePath
        updatePreviewForSelection()
    }

    /// Applies selection emitted by the outline. AppKit reports `nil` when the
    /// user clicks row whitespace; preserving the current row avoids tearing
    /// down and rebuilding the preview for a click that selected no other item.
    func selectFromOutline(_ relativePath: String?) {
        guard let relativePath else { return }
        select(relativePath)
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
        if selectedRelativePath != nil || previewedRelativePath != nil {
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

    /// Selection drives the preview only when a file is chosen. Selecting a
    /// directory (to expand it) leaves the previewed file untouched; only an
    /// explicit deselection (`select(nil)`, Escape, close) tears the preview
    /// down.
    private func updatePreviewForSelection() {
        guard let selectedRelativePath else {
            previewedRelativePath = nil
            clearPreview()
            return
        }
        guard selectedEntry?.isDirectory != true else { return }
        previewedRelativePath = selectedRelativePath
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
