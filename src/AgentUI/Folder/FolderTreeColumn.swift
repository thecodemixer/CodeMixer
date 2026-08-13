import SwiftUI
import AgentCore

/// Reusable outline column for single- and dual-folder tree surfaces.
struct FolderTreeColumn: View {
    @Bindable var treeModel: FolderTreeViewModel
    var accessibilityLabel: String = "Folder tree"
    var minWidth: CGFloat = Theme.layout.folderBrowserListMinWidth
    /// `nil` hands width distribution to the enclosing split view.
    var idealWidth: CGFloat? = Theme.layout.folderBrowserListIdealWidth
    var maxWidth: CGFloat = Theme.layout.folderBrowserListMaxWidth
    var showsPinActions: Bool = true
    var onQuickLook: ((URL) -> Void)?
    var onPin: ((String) -> Void)?
    var onUnpin: ((String) -> Void)?
    var onFocus: (() -> Void)?

    @ViewBuilder
    var body: some View {
        // Attached only when a side needs focus tracking, and simultaneous so the
        // List keeps owning row selection — a plain `onTapGesture` here swallows
        // clicks on rows.
        if let onFocus {
            column.simultaneousGesture(TapGesture().onEnded { onFocus() })
        } else {
            column
        }
    }

    private var column: some View {
        List(selection: Binding(
            get: { treeModel.selectedRelativePath },
            set: { path in
                onFocus?()
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
        .frame(minWidth: minWidth, idealWidth: idealWidth, maxWidth: maxWidth)
        .accessibilityLabel(accessibilityLabel)
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
                    if let onQuickLook {
                        Button("Quick Look") {
                            onQuickLook(treeModel.absoluteURL(for: path))
                        }
                        .accessibilityLabel("Quick Look selected file")
                    }
                    if showsPinActions {
                        pinMenuButton(path: path)
                    }
                }
            }
        }
        .onKeyPress(.rightArrow) {
            onFocus?()
            guard let path = treeModel.selectedRelativePath,
                  let entry = treeModel.selectedEntry,
                  entry.isDirectory else { return .ignored }
            treeModel.setExpanded(path, expanded: true)
            return .handled
        }
        .onKeyPress(.leftArrow) {
            onFocus?()
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
            onFocus?()
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
    private func pinMenuButton(path: String) -> some View {
        let pinned = treeModel.pinnedRelativePaths.contains(path)
        let pinLimitReached = treeModel.pinnedRelativePaths.count >= FolderViewState.maxPinnedPaths
        if pinned {
            Button("Unpin from Sidebar") {
                onUnpin?(path)
            }
            .accessibilityLabel("Unpin \(path) from sidebar")
        } else {
            Button("Pin to Sidebar") {
                onPin?(path)
            }
            .accessibilityLabel("Pin \(path) to sidebar")
            .disabled(pinLimitReached || onPin == nil)
        }
    }
}

/// Recursive outline row — a concrete `View` type avoids opaque recursive inference.
struct FolderTreeOutlineRow: View {
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
