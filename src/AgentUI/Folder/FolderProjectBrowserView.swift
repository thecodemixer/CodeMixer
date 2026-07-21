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
    @State private var fileTableSortOrder = [FolderTableSort(field: .name)]
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
        .padding(Theme.spacing.s16)
        .background(Theme.surface.panel)
    }

    private func searchBar(_ browser: FolderProjectBrowserModel) -> some View {
        HStack(spacing: Theme.spacing.s8) {
            Image(systemName: "magnifyingglass")
                .foregroundStyle(Theme.text.tertiary)
                .imageScale(.small)
            TextField("Search files", text: Binding(
                get: { browser.searchText },
                set: { browser.searchText = $0 }
            ))
            .textFieldStyle(.plain)
            .font(Theme.typography.caption)
            .focused($searchFocused)
            .accessibilityLabel("Search files")
            if !browser.searchText.isEmpty || browser.extensionFilter != nil {
                Button {
                    browser.clearSearchAndFilters()
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .foregroundStyle(Theme.text.tertiary)
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Clear search and filters")
            }
        }
        .padding(.horizontal, Theme.spacing.s16)
        .padding(.vertical, Theme.spacing.s8)
        .background(Theme.surface.panel)
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

    @ViewBuilder
    private func fileTable(_ browser: FolderProjectBrowserModel, compact: Bool) -> some View {
        // Beside preview, keep a name-only list — Pin column is full-list only.
        if compact {
            compactPlainFileTable(browser)
        } else if kind.supportsPinnedSidebarEntries {
            fullPinnedFileTable(browser)
        } else {
            fullPlainFileTable(browser)
        }
    }

    private func compactPlainFileTable(_ browser: FolderProjectBrowserModel) -> some View {
        Table(of: FolderFileEntry.self, selection: Binding(
            get: { browser.selectedPaths },
            set: { browser.selectMany($0) }
        )) {
            TableColumn("Name") { (entry: FolderFileEntry) in
                fileNameCell(entry)
            }
            .width(min: Theme.layout.folderBrowserListMinWidth - 48,
                   ideal: Theme.layout.folderBrowserListIdealWidth - 48)
        } rows: {
            ForEach(browser.visibleEntries) { entry in
                TableRow(entry)
            }
        }
        .tableStyle(.inset(alternatesRowBackgrounds: true))
        .contextMenu(forSelectionType: String.self) { selection in
            rowContextMenu(paths: selection, browser: browser)
        } primaryAction: { selection in
            if let path = selection.first {
                DesktopActions.openURL(browser.absoluteURL(for: path))
            }
        }
        .frame(
            minWidth: Theme.layout.folderBrowserListMinWidth,
            idealWidth: Theme.layout.folderBrowserListIdealWidth,
            maxWidth: Theme.layout.folderBrowserListMaxWidth,
            maxHeight: .infinity
        )
        .layoutPriority(0)
    }

    private func fullPlainFileTable(_ browser: FolderProjectBrowserModel) -> some View {
        Table(
            sortedTableRows(browser),
            selection: Binding(
                get: { browser.selectedPaths },
                set: { browser.selectMany($0) }
            ),
            sortOrder: $fileTableSortOrder
        ) {
            TableColumn("Name", sortUsing: FolderTableSort(field: .name)) { (row: FolderBrowserRow) in
                fileNameCell(row.entry)
            }
            .width(min: 180, ideal: 280)

            TableColumn("Kind", sortUsing: FolderTableSort(field: .kind)) { (row: FolderBrowserRow) in
                Text(row.kindLabel)
                    .font(Theme.typography.caption)
                    .foregroundStyle(Theme.text.secondary)
            }
            .width(min: 64, ideal: 80)

            TableColumn("Size", sortUsing: FolderTableSort(field: .size)) { (row: FolderBrowserRow) in
                Text(byteCountString(row.byteCount))
                    .font(Theme.typography.caption)
                    .foregroundStyle(Theme.text.secondary)
                    .monospacedDigit()
            }
            .width(min: 64, ideal: 80)

            TableColumn("Modified", sortUsing: FolderTableSort(field: .modified)) { (row: FolderBrowserRow) in
                Text(row.modifiedAt.formatted(date: .abbreviated, time: .shortened))
                    .font(Theme.typography.caption)
                    .foregroundStyle(Theme.text.secondary)
            }
            .width(min: 120, ideal: 150)
        }
        .tableStyle(.inset(alternatesRowBackgrounds: true))
        .contextMenu(forSelectionType: String.self) { selection in
            rowContextMenu(paths: selection, browser: browser)
        } primaryAction: { selection in
            if let path = selection.first {
                DesktopActions.openURL(browser.absoluteURL(for: path))
            }
        }
        .onChange(of: fileTableSortOrder) { _, order in
            syncSortOrder(order, into: browser)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private func fullPinnedFileTable(_ browser: FolderProjectBrowserModel) -> some View {
        Table(
            sortedTableRows(browser),
            selection: Binding(
                get: { browser.selectedPaths },
                set: { browser.selectMany($0) }
            ),
            sortOrder: $fileTableSortOrder
        ) {
            TableColumn("Name", sortUsing: FolderTableSort(field: .name)) { (row: FolderBrowserRow) in
                fileNameCell(row.entry)
            }
            .width(min: 180, ideal: 280)

            TableColumn("Pin", sortUsing: FolderTableSort(field: .pin)) { (row: FolderBrowserRow) in
                pinCell(for: row.entry)
            }
            .width(min: 44, ideal: 52, max: 64)

            TableColumn("Kind", sortUsing: FolderTableSort(field: .kind)) { (row: FolderBrowserRow) in
                Text(row.kindLabel)
                    .font(Theme.typography.caption)
                    .foregroundStyle(Theme.text.secondary)
            }
            .width(min: 64, ideal: 80)

            TableColumn("Size", sortUsing: FolderTableSort(field: .size)) { (row: FolderBrowserRow) in
                Text(byteCountString(row.byteCount))
                    .font(Theme.typography.caption)
                    .foregroundStyle(Theme.text.secondary)
                    .monospacedDigit()
            }
            .width(min: 64, ideal: 80)

            TableColumn("Modified", sortUsing: FolderTableSort(field: .modified)) { (row: FolderBrowserRow) in
                Text(row.modifiedAt.formatted(date: .abbreviated, time: .shortened))
                    .font(Theme.typography.caption)
                    .foregroundStyle(Theme.text.secondary)
            }
            .width(min: 120, ideal: 150)
        }
        .tableStyle(.inset(alternatesRowBackgrounds: true))
        .contextMenu(forSelectionType: String.self) { selection in
            rowContextMenu(paths: selection, browser: browser)
        } primaryAction: { selection in
            if let path = selection.first {
                DesktopActions.openURL(browser.absoluteURL(for: path))
            }
        }
        .onChange(of: fileTableSortOrder) { _, order in
            syncSortOrder(order, into: browser)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private func tableRows(_ browser: FolderProjectBrowserModel) -> [FolderBrowserRow] {
        browser.filteredEntries.map { entry in
            FolderBrowserRow(
                entry: entry,
                isPinned: browser.pinnedRelativePaths.contains(entry.relativePath)
            )
        }
    }

    /// Table does not reliably re-order custom-cell rows from `sortOrder` alone —
    /// sort explicitly so header clicks always regroup the listing.
    private func sortedTableRows(_ browser: FolderProjectBrowserModel) -> [FolderBrowserRow] {
        tableRows(browser).sorted(using: fileTableSortOrder)
    }

    private func syncSortOrder(_ order: [FolderTableSort],
                               into browser: FolderProjectBrowserModel) {
        guard let first = order.first else { return }
        browser.sortAscending = first.order == .forward
        switch first.field {
        case .name: browser.sortColumn = .name
        case .pin: browser.sortColumn = .pinned
        case .kind: browser.sortColumn = .kind
        case .size: browser.sortColumn = .size
        case .modified: browser.sortColumn = .modified
        }
    }

    private func fileNameCell(_ entry: FolderFileEntry) -> some View {
        HStack(spacing: Theme.spacing.s8) {
            Image(systemName: entry.isDirectory ? "folder" : "doc")
                .foregroundStyle(Theme.text.tertiary)
                .accessibilityHidden(true)
            Text(entry.relativePath)
                .font(Theme.typography.monoSmall)
                .fontDesign(.monospaced)
                .lineLimit(1)
                .truncationMode(.middle)
            Spacer(minLength: 0)
        }
        .accessibilityLabel(entry.relativePath)
    }

    private func pinCell(for entry: FolderFileEntry) -> some View {
        let pinned = (model.folderPinnedPathsByProject[project.path] ?? []).contains(entry.relativePath)
        let pinLimitReached = (model.folderPinnedPathsByProject[project.path] ?? []).count
            >= FolderViewState.maxPinnedPaths
        return Button {
            if pinned {
                model.unpinFolderPath(entry.relativePath, in: project.path)
            } else {
                model.pinFolderPath(entry.relativePath, in: project.path)
            }
        } label: {
            Image(systemName: pinned ? "pin.fill" : "pin")
                .imageScale(.small)
                .foregroundStyle(pinned ? Theme.text.primary : Theme.text.tertiary)
        }
        .buttonStyle(.plain)
        .help(pinned ? "Unpin from Sidebar" : "Pin to Sidebar")
        .accessibilityLabel(
            pinned
                ? "Unpin \(entry.relativePath) from sidebar"
                : "Pin \(entry.relativePath) to sidebar"
        )
        .disabled(!pinned && pinLimitReached)
        .onHover { DesktopActions.setPointingHandCursor($0) }
    }

    @ViewBuilder
    private func rowContextMenu(paths: Set<String>, browser: FolderProjectBrowserModel) -> some View {
        if paths.count > 1 {
            Button("Copy Paths") {
                let joined = paths.sorted().map { browser.absoluteURL(for: $0).path }.joined(separator: "\n")
                DesktopActions.copyToPasteboard(joined)
            }
            .accessibilityLabel("Copy selected paths")
            Button("Reveal in Finder") {
                for path in paths {
                    DesktopActions.revealInFinder(browser.absoluteURL(for: path))
                }
            }
            .accessibilityLabel("Reveal selected files in Finder")
        } else if let path = paths.first {
            Button("Open in Default App") {
                DesktopActions.openURL(browser.absoluteURL(for: path))
            }
            .accessibilityLabel("Open \(path) in default app")
            Button("Reveal in Finder") {
                DesktopActions.revealInFinder(browser.absoluteURL(for: path))
            }
            .accessibilityLabel("Reveal \(path) in Finder")
            Button("Copy Path") {
                DesktopActions.copyToPasteboard(browser.absoluteURL(for: path).path)
            }
            .accessibilityLabel("Copy path \(path)")
            Button("Quick Look") {
                quickLook(url: browser.absoluteURL(for: path))
            }
            .accessibilityLabel("Quick Look \(path)")
            if kind.supportsPinnedSidebarEntries {
                Divider()
                let pins = model.folderPinnedPathsByProject[project.path] ?? []
                if pins.contains(path) {
                    Button("Unpin from Sidebar") {
                        model.unpinFolderPath(path, in: project.path)
                    }
                    .accessibilityLabel("Unpin \(path) from sidebar")
                } else {
                    Button("Pin to Sidebar") {
                        model.pinFolderPath(path, in: project.path)
                    }
                    .disabled(pins.count >= FolderViewState.maxPinnedPaths)
                    .accessibilityLabel("Pin \(path) to sidebar")
                }
            }
        }
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

    private func quickLook(url: URL) {
        let bridge = QuickLookBridge(url: url)
        qlBridge = bridge
        let panel = QLPreviewPanel.shared()
        panel?.dataSource = bridge
        panel?.reloadData()
        if panel?.isVisible == true {
            panel?.orderFront(nil)
        } else {
            panel?.makeKeyAndOrderFront(nil)
        }
    }

    private func byteCountString(_ count: Int) -> String {
        ByteCountFormatter.string(fromByteCount: Int64(count), countStyle: .file)
    }
}

/// Table row wrapper with stored sort keys (computed key paths break Table sorting).
private struct FolderBrowserRow: Identifiable {
    var id: String { entry.relativePath }
    let entry: FolderFileEntry
    let name: String
    let kindLabel: String
    let byteCount: Int
    let modifiedAt: Date
    /// Pinned sorts before unpinned under ascending order.
    let pinSortKey: Int

    init(entry: FolderFileEntry, isPinned: Bool) {
        self.entry = entry
        self.name = entry.relativePath
        self.kindLabel = entry.kindLabel
        self.byteCount = entry.byteCount
        self.modifiedAt = entry.modifiedAt
        self.pinSortKey = isPinned ? 0 : 1
    }
}

/// Explicit comparator so column-header clicks update a typed field (not opaque key paths).
private struct FolderTableSort: SortComparator, Hashable {
    enum Field: Hashable {
        case name
        case pin
        case kind
        case size
        case modified
    }

    var field: Field
    var order: SortOrder = .forward

    func compare(_ lhs: FolderBrowserRow, _ rhs: FolderBrowserRow) -> ComparisonResult {
        let result: ComparisonResult
        switch field {
        case .name:
            result = lhs.name.localizedStandardCompare(rhs.name)
        case .pin:
            if lhs.pinSortKey == rhs.pinSortKey {
                result = lhs.name.localizedStandardCompare(rhs.name)
            } else {
                result = lhs.pinSortKey < rhs.pinSortKey ? .orderedAscending : .orderedDescending
            }
        case .kind:
            result = lhs.kindLabel.localizedStandardCompare(rhs.kindLabel)
        case .size:
            if lhs.byteCount == rhs.byteCount {
                result = lhs.name.localizedStandardCompare(rhs.name)
            } else {
                result = lhs.byteCount < rhs.byteCount ? .orderedAscending : .orderedDescending
            }
        case .modified:
            if lhs.modifiedAt == rhs.modifiedAt {
                result = lhs.name.localizedStandardCompare(rhs.name)
            } else {
                result = lhs.modifiedAt < rhs.modifiedAt ? .orderedAscending : .orderedDescending
            }
        }
        return order == .forward ? result : Self.reversed(result)
    }

    private static func reversed(_ result: ComparisonResult) -> ComparisonResult {
        switch result {
        case .orderedAscending: return .orderedDescending
        case .orderedDescending: return .orderedAscending
        case .orderedSame: return .orderedSame
        }
    }
}
