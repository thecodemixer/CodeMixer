import SwiftUI
import AppKit
import Quartz
import AgentCore

/// Dual-root tree browser for `FolderProjectKind.dualFolderTree`.
///
/// Trees sit on the outer edges; previews fill the middle when a file is
/// selected. Sidebar suppression is owned by `WorkspaceScene` via the binding.
struct DualFolderTreeView: View {
    @Bindable var model: EngineViewModel
    let project: WorkspaceProjectsStore.ProjectRef
    @Binding var suppressSidebarForPreviews: Bool

    @State private var coordinator: DualFolderTreeCoordinator?
    @State private var qlBridge: QuickLookBridge?
    @State private var leftTreeWidth: CGFloat?
    @State private var rightTreeWidth: CGFloat?
    @State private var previewSplitFraction: CGFloat = 0.5
    @FocusState private var leftSearchFocused: Bool
    @FocusState private var rightSearchFocused: Bool

    var body: some View {
        Group {
            if let coordinator {
                content(coordinator)
            } else {
                ProgressView("Scanning folders…")
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .accessibilityLabel("Scanning folders")
            }
        }
        .background(Theme.surface.canvas)
        .onAppear { ensureCoordinator() }
        .onChange(of: project.path) { _, _ in recreateCoordinator() }
        .onChange(of: model.dualFolderOverviewResetGeneration) { _, _ in
            coordinator?.resetForProjectOverview()
            suppressSidebarForPreviews = false
        }
        .onDisappear {
            suppressSidebarForPreviews = false
            coordinator?.stop()
        }
    }

    @ViewBuilder
    private func content(_ coordinator: DualFolderTreeCoordinator) -> some View {
        VStack(spacing: 0) {
            topChrome(coordinator)
            Divider()
            if let left = coordinator.leftModel {
                splitBody(coordinator, left: left)
            } else {
                ProgressView("Scanning folders…")
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .accessibilityLabel("Scanning folders")
            }
        }
        .background {
            Button("Dismiss Dual Overlay") {
                if qlBridge != nil, QLPreviewPanel.shared()?.isVisible == true {
                    QLPreviewPanel.shared()?.orderOut(nil)
                    qlBridge = nil
                } else {
                    _ = coordinator.handleEscape()
                }
            }
            .keyboardShortcut(.escape, modifiers: [])
            .hidden()
            // Cmd+F targets the focused side rather than the conversation search,
            // which has no meaning on a folder surface.
            Button("Focus Search") { focusSearch(coordinator) }
                .keyboardShortcut("f", modifiers: .command)
                .hidden()
            Button("Copy Path") { copySelectedPath(coordinator) }
                .keyboardShortcut("c", modifiers: [.command, .shift])
                .hidden()
            Button("Quick Look Selected") { quickLookSelected(coordinator) }
                .keyboardShortcut(.space)
                .hidden()
        }
        .onChange(of: coordinator.leftModel?.selectedRelativePath) { _, _ in
            suppressSidebarForPreviews = (coordinator.layout == .previews)
        }
        .onChange(of: coordinator.rightModel?.selectedRelativePath) { _, _ in
            suppressSidebarForPreviews = (coordinator.layout == .previews)
        }
        .onAppear {
            suppressSidebarForPreviews = (coordinator.layout == .previews)
        }
    }

    private func topChrome(_ coordinator: DualFolderTreeCoordinator) -> some View {
        HStack(spacing: Theme.spacing.s12) {
            Image(systemName: FolderProjectKind.dualFolderTree.systemImage)
                .foregroundStyle(Theme.text.secondary)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: Theme.spacing.s4) {
                Text(FolderProjectKind.dualFolderTree.displayLabel)
                    .font(Theme.typography.label)
                    .foregroundStyle(Theme.text.primary)
                Text(project.path)
                    .font(Theme.typography.caption)
                    .foregroundStyle(Theme.text.tertiary)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
            Spacer(minLength: 0)
            if coordinator.secondaryRootError != nil {
                Button("Choose Compare Folder…") {
                    chooseSecondaryRoot(coordinator)
                }
                .accessibilityLabel("Choose compare folder")
            }
        }
        .panelHeaderChrome()
    }

    @ViewBuilder
    private func splitBody(_ coordinator: DualFolderTreeCoordinator,
                           left: FolderTreeViewModel) -> some View {
        switch coordinator.layout {
        case .treesOnly:
            // `HSplitView` gives every boundary a drag handle and, unlike a
            // horizontal `ScrollView`, never lets a greedy pane grow past the
            // viewport and push a sibling off-screen.
            HSplitView {
                treePane(coordinator, side: .left, treeModel: left,
                         idealWidth: nil)
                if let right = coordinator.rightModel {
                    treePane(coordinator, side: .right, treeModel: right,
                             idealWidth: nil)
                } else {
                    secondaryMissingPane(coordinator)
                }
            }
        case .previews:
            if let right = coordinator.rightModel {
                balancedPreviewSplit(coordinator, left: left, right: right)
            } else {
                HSplitView {
                    treePane(coordinator, side: .left, treeModel: left,
                             idealWidth: Theme.layout.dualFolderTreeListIdealWidth)
                    previewPane(coordinator, side: .left, treeModel: left)
                    secondaryMissingPane(coordinator)
                }
            }
        }
    }

    /// Four-pane geometry with deterministic defaults: equal outer trees and
    /// equal previews. Native `HSplitView` sizes text-heavy children from their
    /// intrinsic width, which made one preview consume nearly the whole center.
    private func balancedPreviewSplit(_ coordinator: DualFolderTreeCoordinator,
                                      left: FolderTreeViewModel,
                                      right: FolderTreeViewModel) -> some View {
        GeometryReader { proxy in
            let layout = DualFolderPaneLayout.resolve(
                availableWidth: proxy.size.width,
                leftTreeWidth: leftTreeWidth,
                rightTreeWidth: rightTreeWidth,
                previewSplitFraction: previewSplitFraction
            )
            ZStack(alignment: .topLeading) {
                treePane(coordinator, side: .left, treeModel: left, idealWidth: nil,
                         minWidth: layout.treeMinimumWidth)
                    .frame(width: layout.leftTreeWidth, height: proxy.size.height)
                    .offset(x: 0)
                previewPane(coordinator, side: .left, treeModel: left,
                            minWidth: layout.previewMinimumWidth)
                    .frame(width: layout.leftPreviewWidth, height: proxy.size.height)
                    .offset(x: layout.leftTreeWidth)
                previewPane(coordinator, side: .right, treeModel: right,
                            minWidth: layout.previewMinimumWidth)
                    .frame(width: layout.rightPreviewWidth, height: proxy.size.height)
                    .offset(x: layout.previewBoundary)
                treePane(coordinator, side: .right, treeModel: right, idealWidth: nil,
                         minWidth: layout.treeMinimumWidth)
                    .frame(width: layout.rightTreeWidth, height: proxy.size.height)
                    .offset(x: layout.rightTreeBoundary)

                resizeHandle(at: layout.leftTreeWidth, height: proxy.size.height) { location in
                    let width = layout.clampedLeftTreeWidth(for: location)
                    leftTreeWidth = width
                    previewSplitFraction = layout.previewFraction(
                        keepingBoundaryAt: layout.previewBoundary,
                        leftTreeWidth: width,
                        rightTreeWidth: layout.rightTreeWidth
                    )
                }
                resizeHandle(at: layout.previewBoundary,
                             height: proxy.size.height,
                             boundary: .gutter) { location in
                    previewSplitFraction = layout.clampedPreviewFraction(for: location)
                }
                resizeHandle(at: layout.rightTreeBoundary, height: proxy.size.height) { location in
                    let width = layout.clampedRightTreeWidth(for: location)
                    rightTreeWidth = width
                    previewSplitFraction = layout.previewFraction(
                        keepingBoundaryAt: layout.previewBoundary,
                        leftTreeWidth: layout.leftTreeWidth,
                        rightTreeWidth: width
                    )
                }
            }
            .coordinateSpace(name: DualFolderPaneLayout.coordinateSpaceName)
        }
    }

    private func resizeHandle(at x: CGFloat,
                              height: CGFloat,
                              boundary: PaneBoundary = .hairline,
                              onDrag: @escaping (CGFloat) -> Void) -> some View {
        ZStack {
            boundaryBand(boundary)
            Rectangle()
                .fill(Color.clear)
                .contentShape(Rectangle())
        }
        .frame(width: boundary.hitWidth, height: height)
        .offset(x: x - boundary.hitWidth / 2)
        .onHover { hovering in
            if hovering {
                NSCursor.resizeLeftRight.push()
            } else {
                NSCursor.pop()
            }
        }
        .gesture(
            DragGesture(minimumDistance: 0,
                        coordinateSpace: .named(DualFolderPaneLayout.coordinateSpaceName))
                .onChanged { onDrag($0.location.x) }
        )
        .accessibilityLabel("Resize adjacent panels")
    }

    /// How strongly a pane boundary reads. A tree beside a preview is already
    /// obvious from its content, but the two previews are both monospaced file
    /// bodies — across a hairline, the right file's first column looks like a
    /// continuation of the left file's line.
    private enum PaneBoundary {
        case hairline
        case gutter

        var hitWidth: CGFloat {
            switch self {
            case .hairline: Theme.spacing.s8
            case .gutter: Theme.spacing.s12
            }
        }
    }

    @ViewBuilder
    private func boundaryBand(_ boundary: PaneBoundary) -> some View {
        switch boundary {
        case .hairline:
            Rectangle()
                .fill(Theme.surface.divider)
                .frame(width: Theme.stroke.standard)
        case .gutter:
            Rectangle()
                .fill(Theme.surface.panel)
                .frame(width: Theme.spacing.s8)
                .overlay(alignment: .leading) { gutterEdge }
                .overlay(alignment: .trailing) { gutterEdge }
        }
    }

    private var gutterEdge: some View {
        Rectangle()
            .fill(Theme.surface.divider)
            .frame(width: Theme.stroke.standard)
    }

    /// `idealWidth` nil lets two trees share the width evenly; in preview mode a
    /// narrow ideal keeps the trees slim so both previews stay readable, while
    /// the drag handles still allow any width down to the pane minimum.
    private func treePane(_ coordinator: DualFolderTreeCoordinator,
                          side: DualFolderTreeSide,
                          treeModel: FolderTreeViewModel,
                          idealWidth: CGFloat?,
                          minWidth: CGFloat = Theme.layout.dualFolderTreeListMinWidth) -> some View {
        VStack(spacing: 0) {
            sideHeader(treeModel, side: side, coordinator: coordinator)
            Divider()
            searchBar(treeModel, side: side, coordinator: coordinator)
            if treeModel.showFilters {
                filterBar(treeModel)
            }
            if treeModel.truncated {
                FolderTreeTruncationBanner()
            }
            if let error = treeModel.lastError {
                FolderTreeRecoveryBanner(
                    title: "Could not scan \(treeModel.root.lastPathComponent)",
                    detail: error,
                    actionTitle: "Retry",
                    action: {
                        coordinator.focus(side)
                        treeModel.refresh()
                    }
                )
            }
            treeBody(coordinator, side: side, treeModel: treeModel, minWidth: minWidth)
                .frame(maxHeight: .infinity)
        }
        // Each side reports its own scan state, so a failing compare root never
        // blanks the primary tree.
        .frame(minWidth: minWidth,
               idealWidth: idealWidth,
               maxWidth: .infinity)
    }

    @ViewBuilder
    private func treeBody(_ coordinator: DualFolderTreeCoordinator,
                          side: DualFolderTreeSide,
                          treeModel: FolderTreeViewModel,
                          minWidth: CGFloat) -> some View {
        let rootName = treeModel.root.lastPathComponent
        if treeModel.isLoading, treeModel.entries.isEmpty {
            ProgressView("Scanning \(rootName)…")
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .accessibilityLabel("Scanning \(rootName)")
        } else if treeModel.isEmptyListing {
            FolderTreeEmptyState(
                title: "Empty folder",
                systemImage: "folder",
                detail: "Add files to \(rootName), then refresh.",
                actionTitle: "Refresh",
                action: {
                    coordinator.focus(side)
                    treeModel.refresh()
                }
            )
        } else if treeModel.hasActiveFilter, treeModel.visibleTreeRoots.isEmpty {
            FolderTreeEmptyState(
                title: "No matching files",
                systemImage: "magnifyingglass",
                detail: "Try a different search or clear the filters for \(rootName).",
                actionTitle: "Clear Filters",
                action: {
                    coordinator.focus(side)
                    treeModel.searchText = ""
                    treeModel.extensionFilter = nil
                }
            )
        } else {
            FolderTreeColumn(
                treeModel: treeModel,
                accessibilityLabel: side == .left ? "Primary folder tree" : "Compare folder tree",
                minWidth: minWidth,
                // The enclosing split pane owns the width; the list fills it so a
                // dragged-wider tree does not leave dead space.
                idealWidth: nil,
                maxWidth: .infinity,
                showsPinActions: false,
                onQuickLook: { url in quickLook(url: url) },
                onFocus: { coordinator.focus(side) }
            )
        }
    }

    @ViewBuilder
    private func previewPane(_ coordinator: DualFolderTreeCoordinator,
                             side: DualFolderTreeSide,
                             treeModel: FolderTreeViewModel,
                             minWidth: CGFloat = Theme.layout.dualFolderPreviewMinWidth) -> some View {
        let rootName = treeModel.root.lastPathComponent
        if treeModel.selectedRelativePath == nil || treeModel.selectedEntry?.isDirectory == true {
            ContentUnavailableView(
                "Select a file",
                systemImage: "doc.text.magnifyingglass",
                description: Text("Choose a file in \(rootName) to preview its contents.")
            )
            .frame(minWidth: minWidth)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .layoutPriority(1)
            .accessibilityLabel("Select a file in \(rootName)")
        } else {
            FolderTreePreviewPanel(
                model: treeModel,
                onClose: { coordinator.closePreviews() },
                rootContextTitle: rootName,
                minWidth: minWidth,
                bindsEscapeShortcut: false
            )
        }
    }

    private func secondaryMissingPane(_ coordinator: DualFolderTreeCoordinator) -> some View {
        VStack(spacing: Theme.spacing.s16) {
            ContentUnavailableView(
                "Compare folder unavailable",
                systemImage: "folder.badge.questionmark",
                description: Text(coordinator.secondaryRootError
                                   ?? "Choose a second folder to compare.")
            )
            Button("Choose Folder…") {
                chooseSecondaryRoot(coordinator)
            }
            .accessibilityLabel("Choose compare folder")
        }
        .frame(minWidth: Theme.layout.dualFolderTreeListMinWidth)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private func sideHeader(_ treeModel: FolderTreeViewModel,
                            side: DualFolderTreeSide,
                            coordinator: DualFolderTreeCoordinator) -> some View {
        HStack(spacing: Theme.spacing.s8) {
            Text(treeModel.root.lastPathComponent)
                .font(Theme.typography.label)
                .foregroundStyle(Theme.text.primary)
                .lineLimit(1)
            Spacer(minLength: 0)
            if treeModel.isLoading {
                ProgressView()
                    .controlSize(.small)
                    .accessibilityLabel("Refreshing")
            }
            Text("\(treeModel.filterMatchCount) of \(treeModel.fileCount)")
                .font(Theme.typography.caption)
                .foregroundStyle(Theme.text.tertiary)
            Button {
                coordinator.focus(side)
                treeModel.showFilters.toggle()
            } label: {
                Image(systemName: "line.3.horizontal.decrease.circle")
            }
            .buttonStyle(.plain)
            .help("Filter by extension")
            .accessibilityLabel(side == .left
                                ? "Toggle primary extension filters"
                                : "Toggle compare extension filters")
            Button {
                coordinator.focus(side)
                treeModel.refresh()
            } label: {
                Image(systemName: "arrow.clockwise")
            }
            .buttonStyle(.plain)
            .help("Refresh folder")
            .accessibilityLabel(side == .left ? "Refresh primary folder" : "Refresh compare folder")
        }
        .panelHeaderChrome(verticalPadding: Theme.spacing.s8)
    }

    private func searchBar(_ treeModel: FolderTreeViewModel,
                           side: DualFolderTreeSide,
                           coordinator: DualFolderTreeCoordinator) -> some View {
        let focus = side == .left ? $leftSearchFocused : $rightSearchFocused
        return SearchFieldBar(
            systemImage: "magnifyingglass",
            placeholder: "Filter files",
            text: Binding(
                get: { treeModel.searchText },
                set: {
                    coordinator.focus(side)
                    treeModel.searchText = $0
                }
            ),
            focus: focus,
            showsClear: !treeModel.searchText.isEmpty,
            clearAccessibilityLabel: side == .left
                ? "Clear primary file filter"
                : "Clear compare file filter",
            onClear: {
                coordinator.focus(side)
                treeModel.searchText = ""
            }
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

    private func ensureCoordinator() {
        guard coordinator == nil else { return }
        recreateCoordinator()
    }

    private func recreateCoordinator() {
        coordinator?.stop()
        suppressSidebarForPreviews = false
        let secondary = ProjectLocalStateStore.load(
            from: URL(fileURLWithPath: project.path),
            fileSystem: SystemFileSystem()
        )?.folderView?.secondaryRootPath
        let created = DualFolderTreeCoordinator(
            primaryRoot: URL(fileURLWithPath: project.path),
            secondaryRoot: secondary.map { URL(fileURLWithPath: $0, isDirectory: true) }
        )
        coordinator = created
        created.start()
    }

    private func chooseSecondaryRoot(_ coordinator: DualFolderTreeCoordinator) {
        guard let url = DesktopActions.chooseDirectoryPanel(prompt: "Choose Compare Folder") else {
            return
        }
        _ = coordinator.replaceSecondaryRoot(url)
    }

    private func focusedModel(_ coordinator: DualFolderTreeCoordinator) -> FolderTreeViewModel? {
        switch coordinator.focusedSide {
        case .left: return coordinator.leftModel
        case .right: return coordinator.rightModel
        case .none: return coordinator.leftModel ?? coordinator.rightModel
        }
    }

    private func focusSearch(_ coordinator: DualFolderTreeCoordinator) {
        if coordinator.focusedSide == .right, coordinator.rightModel != nil {
            rightSearchFocused = true
        } else {
            leftSearchFocused = true
        }
    }

    private func copySelectedPath(_ coordinator: DualFolderTreeCoordinator) {
        guard let treeModel = focusedModel(coordinator),
              let path = treeModel.selectedRelativePath else { return }
        DesktopActions.copyToPasteboard(treeModel.absoluteURL(for: path).path)
    }

    private func quickLookSelected(_ coordinator: DualFolderTreeCoordinator) {
        guard let treeModel = focusedModel(coordinator),
              let path = treeModel.selectedRelativePath,
              treeModel.selectedEntry?.isDirectory != true else { return }
        quickLook(url: treeModel.absoluteURL(for: path))
    }

    private func quickLook(url: URL) {
        qlBridge = presentQuickLook(url: url)
    }
}

#if DEBUG
#Preview("Dual Folder Tree") {
    DualFolderTreeView(
        model: .preview,
        project: WorkspaceProjectsStore.ProjectRef(
            path: PreviewFixtures.workspace.path,
            displayName: PreviewFixtures.ProjectNames.sample,
            projectType: .folder(.dualFolderTree)
        ),
        suppressSidebarForPreviews: .constant(false)
    )
    .frame(width: 1100, height: 640)
}
#endif
