import SwiftUI
import AgentCore

extension FolderTreeView {
    func treeColumn(_ treeModel: FolderTreeViewModel) -> some View {
        List(selection: Binding(
            get: { treeModel.selectedRelativePath },
            set: { path in
                treeModel.selectFromOutline(path)
                if let path {
                    treeModel.revealPath(path)
                }
            }
        )) {
            ForEach(treeModel.visibleTreeRoots) { node in
                FolderTreeOutlineRow(node: node, treeModel: treeModel)
            }
        }
        .listStyle(.sidebar)
        .frame(
            minWidth: Theme.layout.folderBrowserListMinWidth,
            idealWidth: Theme.layout.folderBrowserListIdealWidth,
            maxWidth: Theme.layout.folderBrowserListMaxWidth
        )
        .accessibilityLabel("Folder tree")
        .contextMenu {
            Button("Expand All") { treeModel.expandAll() }
                .accessibilityLabel("Expand all folders")
            Button("Collapse All") { treeModel.collapseAll() }
                .accessibilityLabel("Collapse all folders")
            Divider()
            if let path = treeModel.selectedRelativePath {
                Button("Open") {
                    DesktopActions.openURL(treeModel.absoluteURL(for: path))
                }
                .accessibilityLabel("Open selected item")
                Button("Reveal in Finder") {
                    DesktopActions.revealInFinder(treeModel.absoluteURL(for: path))
                }
                .accessibilityLabel("Reveal selected item in Finder")
                Button("Copy Path") {
                    DesktopActions.copyToPasteboard(treeModel.absoluteURL(for: path).path)
                }
                .accessibilityLabel("Copy selected path")
                if treeModel.selectedEntry?.isDirectory != true {
                    Button("Quick Look") {
                        quickLook(url: treeModel.absoluteURL(for: path))
                    }
                    .accessibilityLabel("Quick Look selected file")
                    if FolderProjectKind.folderTree.supportsPinnedSidebarEntries {
                        pinMenuButton(path: path, treeModel: treeModel)
                    }
                }
            }
        }
        .onKeyPress(.rightArrow) {
            guard let path = treeModel.selectedRelativePath,
                  let entry = treeModel.selectedEntry,
                  entry.isDirectory else { return .ignored }
            treeModel.setExpanded(path, expanded: true)
            return .handled
        }
        .onKeyPress(.leftArrow) {
            guard let path = treeModel.selectedRelativePath else { return .ignored }
            if let entry = treeModel.selectedEntry, entry.isDirectory, treeModel.isExpanded(path) {
                treeModel.setExpanded(path, expanded: false)
                return .handled
            }
            guard let parent = treeModel.parentOfSelection() else { return .ignored }
            treeModel.select(parent)
            return .handled
        }
        .onKeyPress(.return) {
            guard let path = treeModel.selectedRelativePath else { return .ignored }
            if treeModel.selectedEntry?.isDirectory == true {
                treeModel.toggleExpanded(path)
            } else {
                DesktopActions.openURL(treeModel.absoluteURL(for: path))
            }
            return .handled
        }
    }

    @ViewBuilder
    private func pinMenuButton(path: String, treeModel: FolderTreeViewModel) -> some View {
        let pinned = treeModel.pinnedRelativePaths.contains(path)
        let pinLimitReached = treeModel.pinnedRelativePaths.count >= FolderViewState.maxPinnedPaths
        if pinned {
            Button("Unpin from Sidebar") {
                model.unpinFolderPath(path, in: project.path)
            }
            .accessibilityLabel("Unpin \(path) from sidebar")
        } else {
            Button("Pin to Sidebar") {
                model.pinFolderPath(path, in: project.path)
            }
            .accessibilityLabel("Pin \(path) to sidebar")
            .disabled(pinLimitReached)
        }
    }
}

/// Recursive outline row — a concrete `View` type avoids opaque recursive inference.
private struct FolderTreeOutlineRow: View {
    let node: FolderTreeNode
    @Bindable var treeModel: FolderTreeViewModel

    var body: some View {
        if node.entry.isDirectory {
            DisclosureGroup(
                isExpanded: Binding(
                    get: { treeModel.isExpanded(node.entry.relativePath) },
                    set: { treeModel.setExpanded(node.entry.relativePath, expanded: $0) }
                )
            ) {
                ForEach(node.children) { child in
                    FolderTreeOutlineRow(node: child, treeModel: treeModel)
                }
            } label: {
                label(for: node.entry)
                    .contentShape(Rectangle())
                    // Simultaneous so the List keeps its own selection handling;
                    // the disclosure triangle drives the binding directly.
                    .simultaneousGesture(TapGesture().onEnded {
                        treeModel.activate(node.entry.relativePath)
                    })
                    .tag(node.entry.relativePath)
            }
        } else {
            label(for: node.entry)
                .tag(node.entry.relativePath)
        }
    }

    private func label(for entry: FolderFileEntry) -> some View {
        HStack(spacing: Theme.spacing.s8) {
            Image(systemName: FolderFileIcon.systemImage(for: entry))
                .foregroundStyle(Theme.text.tertiary)
                .accessibilityHidden(true)
            Text(entry.name)
                .font(Theme.typography.body)
                .lineLimit(1)
                .truncationMode(.middle)
            Spacer(minLength: 0)
        }
        .accessibilityLabel(entry.isDirectory ? "Folder \(entry.name)" : entry.name)
    }
}
