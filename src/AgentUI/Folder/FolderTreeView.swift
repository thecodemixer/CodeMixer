import SwiftUI
import AppKit
import Quartz
import AgentCore

/// Main-area tree browser for `FolderProjectKind.folderTree` projects.
struct FolderTreeView: View {
    @Bindable var model: EngineViewModel
    let project: WorkspaceProjectsStore.ProjectRef

    @State private var treeModel: FolderTreeViewModel?
    @State private var qlBridge: QuickLookBridge?
    @FocusState private var searchFocused: Bool

    var body: some View {
        Group {
            if let treeModel {
                content(treeModel)
            } else {
                ProgressView("Scanning folder…")
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .accessibilityLabel("Scanning folder")
            }
        }
        .background(Theme.surface.canvas)
        .onAppear { ensureModel() }
        .onChange(of: project.path) { _, _ in recreateModel() }
        .onChange(of: model.pendingFolderSelectionRelativePath) { _, path in
            guard !model.showsPreviewOnly else { return }
            if let path, let treeModel {
                treeModel.consumePendingSelection(path)
                treeModel.revealPath(path)
                model.pendingFolderSelectionRelativePath = nil
                model.setActiveFolderSelection(path)
            }
        }
        .onDisappear {
            treeModel?.stop()
        }
    }

    @ViewBuilder
    private func content(_ treeModel: FolderTreeViewModel) -> some View {
        VStack(spacing: 0) {
            header(treeModel)
            Divider()
            searchBar(treeModel)
            if treeModel.showFilters {
                filterBar(treeModel)
            }
            if treeModel.truncated {
                FolderTreeTruncationBanner()
            }
            if let error = treeModel.lastError {
                FolderTreeRecoveryBanner(
                    title: "Could not scan folder",
                    detail: error,
                    actionTitle: "Retry",
                    action: { treeModel.refresh() }
                )
            }
            Group {
                if treeModel.isLoading && treeModel.entries.isEmpty {
                    ProgressView("Scanning folder…")
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                        .accessibilityLabel("Scanning folder")
                } else if treeModel.isEmptyListing {
                    VStack(spacing: Theme.spacing.s16) {
                        ContentUnavailableView(
                            "Empty folder",
                            systemImage: "folder",
                            description: Text("Add files to this project folder, then refresh.")
                        )
                        Button("Refresh") {
                            treeModel.refresh()
                            model.refreshFolderSidebarShortcuts(for: project)
                        }
                        .accessibilityLabel("Refresh empty folder")
                    }
                } else if treeModel.hasActiveFilter && treeModel.visibleTreeRoots.isEmpty {
                    ContentUnavailableView(
                        "No matching files",
                        systemImage: "magnifyingglass",
                        description: Text("Try a different search or clear filters.")
                    )
                } else {
                    // Split view rather than a fixed divider so the tree/preview
                    // boundary is draggable.
                    HSplitView {
                        treeColumn(treeModel)
                        if treeModel.selectedRelativePath == nil
                            || treeModel.selectedEntry?.isDirectory == true {
                            selectAFilePlaceholder
                        } else {
                            FolderTreePreviewPanel(
                                model: treeModel,
                                onClose: { treeModel.closePreview() }
                            )
                        }
                    }
                }
            }
        }
        .background {
            Button("Focus Search") { searchFocused = true }
                .keyboardShortcut("f", modifiers: .command)
                .hidden()
            Button("Copy Path") { copySelectedPath(treeModel) }
                .keyboardShortcut("c", modifiers: [.command, .shift])
                .hidden()
            Button("Open Selected") { openSelected(treeModel) }
                .keyboardShortcut(.defaultAction)
                .hidden()
            Button("Quick Look Selected") { quickLookSelected(treeModel) }
                .keyboardShortcut(.space)
                .hidden()
            Button("Expand All") { treeModel.expandAll() }
                .keyboardShortcut(.rightArrow, modifiers: .option)
                .hidden()
            Button("Collapse All") { treeModel.collapseAll() }
                .keyboardShortcut(.leftArrow, modifiers: .option)
                .hidden()
            Button("Dismiss Overlay") {
                if qlBridge != nil, QLPreviewPanel.shared()?.isVisible == true {
                    QLPreviewPanel.shared()?.orderOut(nil)
                    qlBridge = nil
                } else {
                    _ = treeModel.handleEscape()
                }
            }
            .keyboardShortcut(.escape, modifiers: [])
            .hidden()
        }
        .onAppear {
            searchFocused = false
            syncPinnedPaths(into: treeModel)
            model.setActiveFolderSelection(treeModel.selectedRelativePath)
        }
        .onChange(of: treeModel.selectedRelativePath) { _, path in
            model.setActiveFolderSelection(path)
        }
        .onChange(of: model.folderPinnedPathsByProject[project.path] ?? []) { _, _ in
            syncPinnedPaths(into: treeModel)
        }
    }

    private var selectAFilePlaceholder: some View {
        ContentUnavailableView(
            "Select a file",
            systemImage: "doc.text.magnifyingglass",
            description: Text("Choose a file in the tree to preview its contents.")
        )
        .frame(minWidth: Theme.layout.folderPreviewMinWidth)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .layoutPriority(1)
    }

    private func syncPinnedPaths(into treeModel: FolderTreeViewModel) {
        treeModel.pinnedRelativePaths = Set(model.folderPinnedPathsByProject[project.path] ?? [])
    }

    private func header(_ treeModel: FolderTreeViewModel) -> some View {
        HStack(spacing: Theme.spacing.s12) {
            Image(systemName: FolderProjectKind.folderTree.systemImage)
                .foregroundStyle(Theme.text.secondary)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: Theme.spacing.s4) {
                Text(FolderProjectKind.folderTree.displayLabel)
                    .font(Theme.typography.label)
                    .foregroundStyle(Theme.text.primary)
                Text(project.path)
                    .font(Theme.typography.caption)
                    .foregroundStyle(Theme.text.tertiary)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
            Spacer(minLength: 0)
            if treeModel.isLoading {
                ProgressView()
                    .controlSize(.small)
                    .accessibilityLabel("Refreshing")
            }
            if let refreshed = treeModel.lastRefreshedAt {
                Text("Updated \(refreshed.formatted(date: .omitted, time: .shortened))")
                    .font(Theme.typography.caption)
                    .foregroundStyle(Theme.text.tertiary)
            }
            Text("\(treeModel.filterMatchCount) of \(treeModel.fileCount)")
                .font(Theme.typography.caption)
                .foregroundStyle(Theme.text.tertiary)
                .accessibilityLabel(
                    "\(treeModel.filterMatchCount) visible of \(treeModel.fileCount) files"
                )
            Button {
                treeModel.expandAll()
            } label: {
                Image(systemName: "arrow.up.left.and.arrow.down.right")
            }
            .buttonStyle(.plain)
            .help("Expand all folders")
            .accessibilityLabel("Expand all folders")
            Button {
                treeModel.collapseAll()
            } label: {
                Image(systemName: "arrow.down.right.and.arrow.up.left")
            }
            .buttonStyle(.plain)
            .help("Collapse all folders")
            .accessibilityLabel("Collapse all folders")
            Button {
                treeModel.showFilters.toggle()
            } label: {
                Image(systemName: "line.3.horizontal.decrease.circle")
            }
            .buttonStyle(.plain)
            .help("Filter by extension")
            .accessibilityLabel("Toggle extension filters")
            Button {
                treeModel.refresh()
                model.refreshFolderSidebarShortcuts(for: project)
            } label: {
                Image(systemName: "arrow.clockwise")
            }
            .buttonStyle(.plain)
            .help("Refresh folder")
            .accessibilityLabel("Refresh folder")
        }
        .panelHeaderChrome()
    }

    private func searchBar(_ treeModel: FolderTreeViewModel) -> some View {
        SearchFieldBar(
            systemImage: "magnifyingglass",
            placeholder: "Filter files",
            text: Binding(get: { treeModel.searchText }, set: { treeModel.searchText = $0 }),
            focus: $searchFocused,
            showsClear: !treeModel.searchText.isEmpty,
            clearAccessibilityLabel: "Clear file filter",
            onClear: { treeModel.searchText = "" }
        )
    }

    private func filterBar(_ treeModel: FolderTreeViewModel) -> some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: Theme.spacing.s8) {
                filterChip(title: "All", selected: treeModel.extensionFilter == nil) {
                    treeModel.extensionFilter = nil
                }
                ForEach(treeModel.availableExtensions, id: \.self) { ext in
                    filterChip(title: ".\(ext)", selected: treeModel.extensionFilter == ext) {
                        treeModel.extensionFilter = ext
                    }
                }
            }
            .padding(.horizontal, Theme.spacing.s16)
            .padding(.vertical, Theme.spacing.s8)
        }
        .background(Theme.surface.panel)
    }

    private func filterChip(title: String, selected: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text(title)
                .font(Theme.typography.caption)
                .foregroundStyle(selected ? Theme.text.primary : Theme.text.secondary)
                .padding(.horizontal, Theme.spacing.s8)
                .padding(.vertical, Theme.spacing.s4)
                .background(selected ? Theme.surface.bubbleUser : Theme.surface.bubble, in: Capsule())
        }
        .buttonStyle(.plain)
        .accessibilityLabel("Filter \(title)")
        .accessibilityAddTraits(selected ? [.isSelected] : [])
    }

    private func ensureModel() {
        guard treeModel == nil else { return }
        recreateModel()
    }

    private func recreateModel() {
        treeModel?.stop()
        let created = FolderTreeViewModel(
            root: URL(fileURLWithPath: project.path),
            initialRelativePath: model.pendingFolderSelectionRelativePath
        )
        treeModel = created
        model.pendingFolderSelectionRelativePath = nil
        created.start()
    }

    private func openSelected(_ treeModel: FolderTreeViewModel) {
        guard let path = treeModel.selectedRelativePath else { return }
        let entry = treeModel.selectedEntry
        if entry?.isDirectory == true {
            treeModel.toggleExpanded(path)
            return
        }
        DesktopActions.openURL(treeModel.absoluteURL(for: path))
    }

    private func copySelectedPath(_ treeModel: FolderTreeViewModel) {
        guard let path = treeModel.selectedRelativePath else { return }
        DesktopActions.copyToPasteboard(treeModel.absoluteURL(for: path).path)
    }

    private func quickLookSelected(_ treeModel: FolderTreeViewModel) {
        guard let path = treeModel.selectedRelativePath,
              treeModel.selectedEntry?.isDirectory != true else { return }
        quickLook(url: treeModel.absoluteURL(for: path))
    }

    func quickLook(url: URL) {
        qlBridge = presentQuickLook(url: url)
    }
}

#if DEBUG
#Preview("Folder Tree") {
    FolderTreeView(
        model: .preview,
        project: WorkspaceProjectsStore.ProjectRef(
            path: PreviewFixtures.workspace.path,
            displayName: PreviewFixtures.ProjectNames.sample,
            projectType: .folder(.folderTree)
        )
    )
    .frame(width: 960, height: 640)
}
#endif
