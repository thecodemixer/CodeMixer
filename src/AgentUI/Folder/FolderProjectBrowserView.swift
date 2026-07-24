import SwiftUI
import AppKit
import Quartz
import AgentCore

/// Main-area folder browser for non-agent `ProjectType.folder` projects.
struct FolderProjectBrowserView: View {
    @Bindable var model: EngineViewModel
    let project: WorkspaceProjectsStore.ProjectRef
    let kind: FolderProjectKind

    @State private var browser: FolderProjectBrowserModel?
    @State private var qlBridge: QuickLookBridge?
    /// Non-private: the file-table builders in `+FileTable.swift` read and
    /// write this via `$fileTableSortOrder`.
    @State var fileTableSortOrder = [FolderTableSort(field: .name)]
    @FocusState private var searchFocused: Bool

    var body: some View {
        Group {
            if let browser {
                content(browser)
            } else {
                ProgressView("Scanning folder…")
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .accessibilityLabel("Scanning folder")
            }
        }
        .background(Theme.surface.canvas)
        .onAppear { ensureBrowser() }
        .onChange(of: project.path) { _, _ in recreateBrowser() }
        .onChange(of: kind) { _, _ in recreateBrowser() }
        .onChange(of: model.pendingFolderSelectionRelativePath) { _, path in
            guard !model.showsPreviewOnly else { return }
            if let path, let browser {
                browser.consumePendingSelection(path)
                model.pendingFolderSelectionRelativePath = nil
                model.setActiveFolderSelection(path)
            }
        }
        .onDisappear {
            browser?.stop()
        }
    }

    @ViewBuilder
    private func content(_ browser: FolderProjectBrowserModel) -> some View {
        VStack(spacing: 0) {
            header(browser)
            Divider()
            searchBar(browser)
            if browser.showFilters {
                filterBar(browser)
            }
            if browser.truncated {
                truncationBanner
            }
            if let notice = browser.logRotationNotice {
                Text(notice)
                    .font(Theme.typography.caption)
                    .foregroundStyle(Theme.signal.warning)
                    .padding(.horizontal, Theme.spacing.s16)
                    .padding(.vertical, Theme.spacing.s8)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(Theme.surface.panel)
                    .accessibilityLabel(notice)
            }
            if let error = browser.lastError {
                recoveryBanner(
                    title: "Could not scan folder",
                    detail: error,
                    actionTitle: "Retry",
                    action: { browser.refresh() }
                )
            }
            Group {
                if browser.isLoading && browser.entries.isEmpty {
                    ProgressView("Scanning folder…")
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                        .accessibilityLabel("Scanning folder")
                } else if browser.isEmptyListing {
                    VStack(spacing: Theme.spacing.s16) {
                        ContentUnavailableView(
                            "Empty folder",
                            systemImage: "folder",
                            description: Text("Add files to this project folder, then refresh.")
                        )
                        Button("Refresh") {
                            browser.refresh()
                            model.refreshFolderSidebarShortcuts(for: project)
                        }
                        .accessibilityLabel("Refresh empty folder")
                    }
                } else {
                    let showsPreview = kind.showsPreviewOnSelection
                        && browser.selectedRelativePath != nil
                    HStack(spacing: 0) {
                        fileTable(browser, compact: showsPreview)
                        if showsPreview {
                            Divider()
                            FilePreviewPanel(
                                browser: browser,
                                kind: kind,
                                onClose: { browser.closePreview() }
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
            Button("Copy Path") { copySelectedPaths(browser) }
                .keyboardShortcut("c", modifiers: [.command, .shift])
                .hidden()
            Button("Open Selected") { openSelected(browser) }
                .keyboardShortcut(.defaultAction)
                .hidden()
            Button("Quick Look Selected") { quickLookSelected(browser) }
                .keyboardShortcut(.space)
                .hidden()
            Button("Dismiss Overlay") {
                if qlBridge != nil, QLPreviewPanel.shared()?.isVisible == true {
                    QLPreviewPanel.shared()?.orderOut(nil)
                    qlBridge = nil
                } else {
                    _ = browser.handleEscape()
                }
            }
            .keyboardShortcut(.escape, modifiers: [])
            .hidden()
        }
        .onAppear {
            searchFocused = false
            syncPinnedPaths(into: browser)
            model.setActiveFolderSelection(browser.selectedRelativePath)
        }
        .onChange(of: browser.selectedRelativePath) { _, path in
            model.setActiveFolderSelection(path)
        }
        .onChange(of: model.folderPinnedPathsByProject[project.path] ?? []) { _, _ in
            syncPinnedPaths(into: browser)
        }
    }

    private func syncPinnedPaths(into browser: FolderProjectBrowserModel) {
        browser.pinnedRelativePaths = Set(model.folderPinnedPathsByProject[project.path] ?? [])
    }

    private func header(_ browser: FolderProjectBrowserModel) -> some View {
        HStack(spacing: Theme.spacing.s12) {
            Image(systemName: kind.systemImage)
                .foregroundStyle(Theme.text.secondary)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: Theme.spacing.s4) {
                Text(kind.displayLabel)
                    .font(Theme.typography.label)
                    .foregroundStyle(Theme.text.primary)
                Text(project.path)
                    .font(Theme.typography.caption)
                    .foregroundStyle(Theme.text.tertiary)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
            Spacer(minLength: 0)
            if browser.isLoading {
                ProgressView()
                    .controlSize(.small)
                    .accessibilityLabel("Refreshing")
            }
            if let refreshed = browser.lastRefreshedAt {
                Text("Updated \(refreshed.formatted(date: .omitted, time: .shortened))")
                    .font(Theme.typography.caption)
                    .foregroundStyle(Theme.text.tertiary)
            }
            Text("\(browser.visibleEntries.count) of \(browser.fileCount)")
                .font(Theme.typography.caption)
                .foregroundStyle(Theme.text.tertiary)
                .accessibilityLabel("\(browser.visibleEntries.count) visible of \(browser.fileCount) files")
            Button {
                browser.showFilters.toggle()
            } label: {
                Image(systemName: "line.3.horizontal.decrease.circle")
            }
            .buttonStyle(.plain)
            .help("Filter by extension")
            .accessibilityLabel("Toggle extension filters")
            Button {
                browser.refresh()
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

    private func searchBar(_ browser: FolderProjectBrowserModel) -> some View {
        SearchFieldBar(
            systemImage: "magnifyingglass",
            placeholder: "Search files",
            text: Binding(get: { browser.searchText }, set: { browser.searchText = $0 }),
            focus: $searchFocused,
            showsClear: !browser.searchText.isEmpty || browser.extensionFilter != nil,
            clearAccessibilityLabel: "Clear search and filters",
            onClear: { browser.clearSearchAndFilters() }
        )
    }

    private func filterBar(_ browser: FolderProjectBrowserModel) -> some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: Theme.spacing.s8) {
                filterChip(
                    title: "All",
                    selected: browser.extensionFilter == nil
                ) {
                    browser.extensionFilter = nil
                }
                ForEach(browser.availableExtensions, id: \.self) { ext in
                    filterChip(
                        title: ".\(ext)",
                        selected: browser.extensionFilter == ext
                    ) {
                        browser.extensionFilter = ext
                    }
                }
            }
            .padding(.horizontal, Theme.spacing.s16)
            .padding(.vertical, Theme.spacing.s8)
        }
        .background(Theme.surface.panel)
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Extension filters")
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

    private var truncationBanner: some View {
        Text("Showing the first \(FolderBrowserLimits.maxScanEntries) entries. Narrow the folder or refresh after cleanup.")
            .font(Theme.typography.caption)
            .foregroundStyle(Theme.signal.warning)
            .padding(.horizontal, Theme.spacing.s16)
            .padding(.vertical, Theme.spacing.s8)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Theme.surface.panel)
            .accessibilityLabel("Folder listing truncated")
    }

    private func recoveryBanner(title: String,
                                detail: String,
                                actionTitle: String,
                                action: @escaping () -> Void) -> some View {
        HStack(alignment: .top, spacing: Theme.spacing.s12) {
            VStack(alignment: .leading, spacing: Theme.spacing.s4) {
                Text(title)
                    .font(Theme.typography.label)
                    .foregroundStyle(Theme.signal.danger)
                Text(detail)
                    .font(Theme.typography.caption)
                    .foregroundStyle(Theme.text.secondary)
            }
            Spacer(minLength: 0)
            Button(actionTitle, action: action)
                .accessibilityLabel(actionTitle)
        }
        .padding(Theme.spacing.s12)
        .background(Theme.surface.panel)
    }

    // MARK: - Helpers

    private func ensureBrowser() {
        guard browser == nil else { return }
        recreateBrowser()
    }

    private func recreateBrowser() {
        browser?.stop()
        let created = FolderProjectBrowserModel(
            root: URL(fileURLWithPath: project.path),
            kind: kind,
            initialRelativePath: model.pendingFolderSelectionRelativePath
        )
        browser = created
        model.pendingFolderSelectionRelativePath = nil
        created.start()
    }

    private func openSelected(_ browser: FolderProjectBrowserModel) {
        let paths = browser.selectedPaths.isEmpty
            ? Set([browser.selectedRelativePath].compactMap { $0 })
            : browser.selectedPaths
        for path in paths {
            DesktopActions.openURL(browser.absoluteURL(for: path))
        }
    }

    private func copySelectedPaths(_ browser: FolderProjectBrowserModel) {
        let paths = browser.selectedPaths.isEmpty
            ? Set([browser.selectedRelativePath].compactMap { $0 })
            : browser.selectedPaths
        guard !paths.isEmpty else { return }
        let joined = paths.sorted().map { browser.absoluteURL(for: $0).path }.joined(separator: "\n")
        DesktopActions.copyToPasteboard(joined)
    }

    private func quickLookSelected(_ browser: FolderProjectBrowserModel) {
        guard let path = browser.selectedRelativePath ?? browser.selectedPaths.sorted().first else { return }
        quickLook(url: browser.absoluteURL(for: path))
    }

    /// Non-private: `+FileTable.swift`'s row context menu also opens Quick Look.
    func quickLook(url: URL) {
        qlBridge = presentQuickLook(url: url)
    }
}
