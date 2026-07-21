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
    @FocusState private var searchFocused: Bool
    @FocusState private var logFindFocused: Bool

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
                            previewPane(browser)
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
            model.setActiveFolderSelection(browser.selectedRelativePath)
        }
        .onChange(of: browser.selectedRelativePath) { _, path in
            model.setActiveFolderSelection(path)
        }
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
        if compact {
            compactFileTable(browser)
        } else {
            fullFileTable(browser)
        }
    }

    private func compactFileTable(_ browser: FolderProjectBrowserModel) -> some View {
        Table(of: FolderFileEntry.self, selection: Binding(
            get: { browser.selectedPaths },
            set: { browser.selectMany($0) }
        )) {
            TableColumn("Name") { (entry: FolderFileEntry) in
                fileNameCell(entry)
            }
            .width(min: Theme.layout.folderBrowserListMinWidth,
                   ideal: Theme.layout.folderBrowserListIdealWidth)
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

    private func fullFileTable(_ browser: FolderProjectBrowserModel) -> some View {
        Table(of: FolderFileEntry.self, selection: Binding(
            get: { browser.selectedPaths },
            set: { browser.selectMany($0) }
        )) {
            TableColumn("Name") { (entry: FolderFileEntry) in
                fileNameCell(entry)
            }
            .width(min: 180, ideal: 280)

            TableColumn("Kind") { (entry: FolderFileEntry) in
                Text(entry.kindLabel)
                    .font(Theme.typography.caption)
                    .foregroundStyle(Theme.text.secondary)
            }
            .width(min: 64, ideal: 80)

            TableColumn("Size") { (entry: FolderFileEntry) in
                Text(byteCountString(entry.byteCount))
                    .font(Theme.typography.caption)
                    .foregroundStyle(Theme.text.secondary)
                    .monospacedDigit()
            }
            .width(min: 64, ideal: 80)

            TableColumn("Modified") { (entry: FolderFileEntry) in
                Text(entry.modifiedAt.formatted(date: .abbreviated, time: .shortened))
                    .font(Theme.typography.caption)
                    .foregroundStyle(Theme.text.secondary)
            }
            .width(min: 120, ideal: 150)
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
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private func fileNameCell(_ entry: FolderFileEntry) -> some View {
        FolderFileNameCell(
            entry: entry,
            supportsPin: kind.supportsPinnedSidebarEntries,
            pinned: (model.folderPinnedPathsByProject[project.path] ?? []).contains(entry.relativePath),
            pinLimitReached: (model.folderPinnedPathsByProject[project.path] ?? []).count
                >= FolderViewState.maxPinnedPaths,
            onPin: { model.pinFolderPath(entry.relativePath, in: project.path) },
            onUnpin: { model.unpinFolderPath(entry.relativePath, in: project.path) }
        )
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

    @ViewBuilder
    private func previewPane(_ browser: FolderProjectBrowserModel) -> some View {
        VStack(spacing: 0) {
            previewHeader(browser)
            if kind == .logs {
                logFindBar(browser)
            }
            Divider()
            HStack(spacing: 0) {
                if kind.usesMarkdownPreview,
                   browser.previewMode == .markdown,
                   !browser.tocItems.isEmpty {
                    tocSidebar(browser)
                    Divider()
                }
                previewBody(browser)
            }
        }
        .frame(minWidth: Theme.layout.folderPreviewMinWidth)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .layoutPriority(1)
        .background(Theme.surface.canvas)
    }

    private func previewHeader(_ browser: FolderProjectBrowserModel) -> some View {
        HStack(spacing: Theme.spacing.s8) {
            Text(browser.previewTitle.isEmpty ? "Preview" : browser.previewTitle)
                .font(Theme.typography.label)
                .lineLimit(1)
            Spacer(minLength: 0)
            if kind == .logs {
                Toggle("Follow", isOn: Binding(
                    get: { browser.followLogs },
                    set: { browser.setFollowLogs($0) }
                ))
                .toggleStyle(.switch)
                .controlSize(.mini)
                .accessibilityLabel("Follow log")
                Toggle("Wrap", isOn: Binding(
                    get: { browser.lineWrap },
                    set: { browser.lineWrap = $0 }
                ))
                .toggleStyle(.switch)
                .controlSize(.mini)
                .accessibilityLabel("Wrap lines")
            }
            if kind.usesMarkdownPreview,
               browser.previewMode == .markdown || browser.previewMode == .source {
                Picker(selection: Binding(
                    get: { browser.docsShowSource },
                    set: { browser.setDocsShowSource($0) }
                )) {
                    Text("Preview")
                        .font(Theme.typography.caption)
                        .tag(false)
                    Text("Source")
                        .font(Theme.typography.caption)
                        .tag(true)
                } label: {
                    EmptyView()
                }
                .labelsHidden()
                .pickerStyle(.segmented)
                .controlSize(.mini)
                .frame(maxWidth: 120)
                .accessibilityLabel("Docs preview mode")
            }
            if browser.previewCapped {
                Text("Showing last \(byteCountString(FolderBrowserLimits.logPreviewTailBytes))")
                    .font(Theme.typography.caption)
                    .foregroundStyle(Theme.text.tertiary)
            }
            if let entry = browser.selectedEntry, kind == .logs {
                Text(byteCountString(entry.byteCount))
                    .font(Theme.typography.caption)
                    .foregroundStyle(Theme.text.tertiary)
                Text(entry.modifiedAt.formatted(date: .abbreviated, time: .shortened))
                    .font(Theme.typography.caption)
                    .foregroundStyle(Theme.text.tertiary)
                    .accessibilityLabel("Last updated \(entry.modifiedAt.formatted())")
            }
            Button {
                browser.closePreview()
            } label: {
                Image(systemName: "xmark")
                    .font(Theme.typography.caption)
                    .foregroundStyle(Theme.text.secondary)
            }
            .buttonStyle(.plain)
            .help("Close preview")
            .accessibilityLabel("Close preview")
            .onHover { DesktopActions.setPointingHandCursor($0) }
        }
        .padding(.horizontal, Theme.spacing.s16)
        .padding(.vertical, Theme.spacing.s8)
        .background(Theme.surface.panel)
    }

    private func logFindBar(_ browser: FolderProjectBrowserModel) -> some View {
        HStack(spacing: Theme.spacing.s8) {
            Image(systemName: "text.magnifyingglass")
                .foregroundStyle(Theme.text.tertiary)
                .imageScale(.small)
            TextField("Find in log", text: Binding(
                get: { browser.logFindText },
                set: { browser.logFindText = $0 }
            ))
            .textFieldStyle(.plain)
            .font(Theme.typography.caption)
            .focused($logFindFocused)
            .accessibilityLabel("Find in log")
            if !browser.logFindText.isEmpty {
                Button {
                    browser.logFindText = ""
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .foregroundStyle(Theme.text.tertiary)
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Clear log find")
            }
        }
        .padding(.horizontal, Theme.spacing.s16)
        .padding(.vertical, Theme.spacing.s8)
        .background(Theme.surface.panel)
    }

    private func tocSidebar(_ browser: FolderProjectBrowserModel) -> some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: Theme.spacing.s4) {
                Text("Contents")
                    .font(Theme.typography.caption)
                    .foregroundStyle(Theme.text.tertiary)
                    .padding(.bottom, Theme.spacing.s4)
                ForEach(Array(browser.tocItems.enumerated()), id: \.element.anchor) { _, item in
                    Button {
                        browser.scrollToTOC(item.anchor)
                    } label: {
                        Text(item.title)
                            .font(Theme.typography.caption)
                            .foregroundStyle(Theme.text.secondary)
                            .lineLimit(2)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(.leading, Theme.spacing.s8 * CGFloat(max(item.level - 1, 0)))
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel("Jump to \(item.title)")
                }
            }
            .padding(Theme.spacing.s12)
        }
        .frame(width: Theme.layout.diffSidebarIdealWidth)
        .background(Theme.surface.panel)
        .accessibilityLabel("Table of contents")
    }

    @ViewBuilder
    private func previewBody(_ browser: FolderProjectBrowserModel) -> some View {
        switch browser.previewMode {
        case .none:
            ContentUnavailableView(
                "Select a file",
                systemImage: "doc.text",
                description: Text(kind == .files
                                   ? "Use Open, Reveal, Quick Look, or Space for a quick peek."
                                   : "Pick a file to preview it here.")
            )
        case .empty:
            ContentUnavailableView(
                "No files yet",
                systemImage: "folder",
                description: Text("This folder has no files to show.")
            )
        case .permissionDenied:
            VStack(spacing: Theme.spacing.s16) {
                ContentUnavailableView(
                    "Permission denied",
                    systemImage: "lock",
                    description: Text(browser.previewText.isEmpty
                                       ? "Codemixer cannot read this file or folder."
                                       : browser.previewText)
                )
                Button("Reveal in Finder") {
                    DesktopActions.revealInFinder(browser.root)
                }
                .accessibilityLabel("Reveal project in Finder")
                Button("Retry") { browser.refresh() }
                    .accessibilityLabel("Retry folder scan")
            }
        case .binary:
            VStack(spacing: Theme.spacing.s16) {
                ContentUnavailableView(
                    "Binary file",
                    systemImage: "doc.zipper",
                    description: Text("Open in the default app or use Quick Look.")
                )
                if let path = browser.selectedRelativePath {
                    HStack(spacing: Theme.spacing.s12) {
                        Button("Open") { DesktopActions.openURL(browser.absoluteURL(for: path)) }
                            .accessibilityLabel("Open selected file")
                        Button("Quick Look") { quickLook(url: browser.absoluteURL(for: path)) }
                            .accessibilityLabel("Quick Look selected file")
                    }
                }
            }
        case .error:
            VStack(spacing: Theme.spacing.s16) {
                ContentUnavailableView(
                    "Preview unavailable",
                    systemImage: "exclamationmark.triangle",
                    description: Text(browser.previewText)
                )
                if let path = browser.selectedRelativePath {
                    Button("Open in Default App") {
                        DesktopActions.openURL(browser.absoluteURL(for: path))
                    }
                    .accessibilityLabel("Open unreadable file in default app")
                }
            }
        case .text:
            ZStack {
                ScrollView {
                    Text(highlightedLogText(browser.previewText, find: browser.logFindText))
                        .font(Theme.typography.monoSmall)
                        .fontDesign(.monospaced)
                        .textSelection(.enabled)
                        .frame(maxWidth: browser.lineWrap ? .infinity : nil, alignment: .leading)
                        .padding(Theme.spacing.s16)
                }
                FolderLogScrollObserver {
                    browser.pauseFollowFromUserScroll()
                }
                .frame(width: 0, height: 0)
            }
        case .source:
            ScrollView {
                Text(browser.previewText)
                    .font(Theme.typography.monoSmall)
                    .fontDesign(.monospaced)
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(Theme.spacing.s16)
            }
        case .markdown:
            LocalMarkdownPreviewView(
                markdown: browser.previewText,
                projectRoot: browser.root,
                documentDirectory: browser.selectedRelativePath.map {
                    browser.absoluteURL(for: $0).deletingLastPathComponent()
                } ?? browser.root,
                scrollToAnchor: browser.pendingTOCAnchor
            )
            .onChange(of: browser.pendingTOCAnchor) { _, anchor in
                if anchor != nil {
                    // Consume after the representable has a chance to scroll.
                    DispatchQueue.main.async {
                        browser.pendingTOCAnchor = nil
                    }
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

    private func highlightedLogText(_ text: String, find: String) -> AttributedString {
        var attributed = AttributedString(text)
        let lower = text.lowercased()
        for token in ["error", "warning", "info", "debug"] {
            var searchStart = lower.startIndex
            while let range = lower.range(of: token, range: searchStart..<lower.endIndex) {
                if let attrRange = Range(range, in: attributed) {
                    switch token {
                    case "error":
                        attributed[attrRange].foregroundColor = Theme.signal.danger
                    case "warning":
                        attributed[attrRange].foregroundColor = Theme.signal.warning
                    case "info":
                        attributed[attrRange].foregroundColor = Theme.signal.info
                    default:
                        attributed[attrRange].foregroundColor = Theme.text.secondary
                    }
                }
                searchStart = range.upperBound
            }
        }
        if !find.isEmpty {
            var searchStart = lower.startIndex
            let needle = find.lowercased()
            while let range = lower.range(of: needle, range: searchStart..<lower.endIndex) {
                if let attrRange = Range(range, in: attributed) {
                    attributed[attrRange].backgroundColor = .yellow.opacity(0.35)
                }
                searchStart = range.upperBound
            }
        }
        return attributed
    }
}

/// Name cell with an inline pin control. Keeps the pin inside the row hit-target
/// so hovering the pin does not dismiss it (Table + overlay IntentReveal drops hover).
private struct FolderFileNameCell: View {
    let entry: FolderFileEntry
    let supportsPin: Bool
    let pinned: Bool
    let pinLimitReached: Bool
    let onPin: () -> Void
    let onUnpin: () -> Void

    @State private var hovering = false

    var body: some View {
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
            if supportsPin {
                Button {
                    if pinned { onUnpin() } else { onPin() }
                } label: {
                    Image(systemName: pinned ? "pin.slash" : "pin")
                        .imageScale(.small)
                }
                .buttonStyle(.plain)
                .help(pinned ? "Unpin from Sidebar" : "Pin to Sidebar")
                .accessibilityLabel(
                    pinned
                        ? "Unpin \(entry.relativePath) from sidebar"
                        : "Pin \(entry.relativePath) to sidebar"
                )
                .disabled(!pinned && pinLimitReached)
                .opacity(hovering || pinned ? 1 : 0)
                .allowsHitTesting(hovering || pinned)
                .onHover { DesktopActions.setPointingHandCursor($0) }
            }
        }
        .contentShape(Rectangle())
        .onHover { hovering = $0 }
        .accessibilityLabel(entry.relativePath)
    }
}
