import Foundation
import Observation
import AgentCore

/// Ephemeral browser state for one active folder project. Preferences are not
/// persisted — only folder kind + pins live in `.codemixer/project.json`.
@MainActor
@Observable
final class FolderProjectBrowserModel {
    enum SortColumn: String, CaseIterable, Identifiable {
        case name
        case pinned
        case kind
        case size
        case modified

        var id: String { rawValue }

        var label: String {
            switch self {
            case .name: return "Name"
            case .pinned: return "Pin"
            case .kind: return "Kind"
            case .size: return "Size"
            case .modified: return "Modified"
            }
        }
    }

    enum PreviewMode: String {
        case none
        case empty
        case text
        case markdown
        case source
        case binary
        case error
        case permissionDenied
    }

    let root: URL
    let kind: FolderProjectKind
    let fileSystem: any FileSystem

    var entries: [FolderFileEntry] = []
    var truncated = false
    var searchText = ""
    var extensionFilter: String?
    var showFilters = false
    var selectedRelativePath: String?
    var selectedPaths: Set<String> = []
    /// Paths currently pinned in the sidebar (pin-capable folder kinds).
    var pinnedRelativePaths: Set<String> = []
    var sortColumn: SortColumn = .name
    var sortAscending = true
    var isLoading = false
    var lastError: String?
    var previewMode: PreviewMode = .none
    var previewText = ""
    var previewCapped = false
    var previewTitle = ""
    var followLogs = true
    var lineWrap = true
    var logFindText = ""
    var logRotationNotice: String?
    var docsShowSource = false
    var tocItems: [(level: Int, title: String, anchor: String)] = []
    var pendingTOCAnchor: String?
    var lastRefreshedAt: Date?
    /// When true, skip directory enumeration and only keep the selected file warm.
    private(set) var isPreviewOnlyListing = false

    private var scanTask: Task<Void, Never>?
    private var previewTask: Task<Void, Never>?
    private var followTask: Task<Void, Never>?
    private var watcher: FSEventsWatcher?
    private var watchTask: Task<Void, Never>?
    private var logReadOffset = 0
    private var previewGeneration = 0

    init(root: URL,
         kind: FolderProjectKind,
         fileSystem: any FileSystem = SystemFileSystem(),
         initialRelativePath: String? = nil) {
        self.root = root.standardizedFileURL
        self.kind = kind
        self.fileSystem = fileSystem
        self.selectedRelativePath = initialRelativePath
        if let initialRelativePath {
            self.selectedPaths = [initialRelativePath]
        }
    }

    var availableExtensions: [String] {
        let exts = Set(entries.compactMap { entry -> String? in
            guard !entry.isDirectory, !entry.fileExtension.isEmpty else { return nil }
            return entry.fileExtension
        })
        return exts.sorted()
    }

    var fileCount: Int {
        entries.filter { !$0.isDirectory }.count
    }

    /// Filtered listing without sort — Table applies `sortOrder` for header clicks.
    var filteredEntries: [FolderFileEntry] {
        let query = searchText.trimmingCharacters(in: .whitespacesAndNewlines)
        return entries.filter { entry in
            guard !entry.isDirectory else { return false }
            if let extensionFilter, entry.fileExtension != extensionFilter {
                return false
            }
            guard !query.isEmpty else { return true }
            return entry.name.localizedCaseInsensitiveContains(query)
                || entry.relativePath.localizedCaseInsensitiveContains(query)
                || entry.fileExtension.localizedCaseInsensitiveContains(query)
        }
    }

    var visibleEntries: [FolderFileEntry] {
        let ascending = sortAscending
        return filteredEntries.sorted { lhs, rhs in
            let comparison: ComparisonResult
            switch sortColumn {
            case .name:
                comparison = lhs.relativePath.localizedStandardCompare(rhs.relativePath)
            case .pinned:
                let lhsPinned = pinnedRelativePaths.contains(lhs.relativePath)
                let rhsPinned = pinnedRelativePaths.contains(rhs.relativePath)
                if lhsPinned == rhsPinned {
                    comparison = lhs.relativePath.localizedStandardCompare(rhs.relativePath)
                } else {
                    // Pinned before unpinned under ascending (default Pin sort).
                    comparison = lhsPinned ? .orderedAscending : .orderedDescending
                }
            case .kind:
                comparison = lhs.kindLabel.localizedStandardCompare(rhs.kindLabel)
            case .size:
                if lhs.byteCount == rhs.byteCount {
                    comparison = lhs.relativePath.localizedStandardCompare(rhs.relativePath)
                } else {
                    comparison = lhs.byteCount < rhs.byteCount ? .orderedAscending : .orderedDescending
                }
            case .modified:
                if lhs.modifiedAt == rhs.modifiedAt {
                    comparison = lhs.relativePath.localizedStandardCompare(rhs.relativePath)
                } else {
                    comparison = lhs.modifiedAt < rhs.modifiedAt ? .orderedAscending : .orderedDescending
                }
            }
            return ascending ? comparison == .orderedAscending : comparison == .orderedDescending
        }
    }

    var selectedEntry: FolderFileEntry? {
        guard let selectedRelativePath else { return nil }
        return entries.first { $0.relativePath == selectedRelativePath }
    }

    var isEmptyListing: Bool {
        !isLoading && lastError == nil && fileCount == 0
    }

    func start(previewOnly: Bool = false) {
        if previewOnly, let path = selectedRelativePath, kind.showsPreviewOnSelection {
            isPreviewOnlyListing = true
            refreshPreviewOnly(relativePath: path)
            startWatching()
        } else {
            isPreviewOnlyListing = false
            refresh()
            startWatching()
        }
    }

    func stop() {
        scanTask?.cancel()
        previewTask?.cancel()
        followTask?.cancel()
        watchTask?.cancel()
        Task { await watcher?.stop() }
        watcher = nil
    }

    func refresh() {
        if isPreviewOnlyListing, let path = selectedRelativePath {
            refreshPreviewOnly(relativePath: path)
            return
        }
        let preservedSearch = searchText
        let preservedSort = sortColumn
        let preservedAscending = sortAscending
        let preservedFilter = extensionFilter
        let preservedSelection = selectedRelativePath
        scanTask?.cancel()
        isLoading = true
        lastError = nil
        let root = root
        let fileSystem = fileSystem
        scanTask = Task { [weak self] in
            do {
                let result = try FolderProjectScanner.scanDetailed(
                    root: root,
                    fileSystem: fileSystem
                )
                guard !Task.isCancelled else { return }
                await MainActor.run {
                    guard let self else { return }
                    self.entries = result.entries
                    self.truncated = result.truncated
                    self.isLoading = false
                    self.lastRefreshedAt = Date()
                    self.searchText = preservedSearch
                    self.sortColumn = preservedSort
                    self.sortAscending = preservedAscending
                    if let preservedFilter,
                       result.entries.contains(where: { $0.fileExtension == preservedFilter }) {
                        self.extensionFilter = preservedFilter
                    } else if preservedFilter != nil {
                        self.extensionFilter = nil
                    }
                    if let selected = preservedSelection,
                       result.entries.contains(where: { $0.relativePath == selected }) {
                        self.selectedRelativePath = selected
                        self.selectedPaths = [selected]
                        self.loadPreview(for: selected)
                    } else if preservedSelection != nil {
                        self.selectedRelativePath = nil
                        self.selectedPaths = []
                        self.clearPreview()
                        if result.entries.filter({ !$0.isDirectory }).isEmpty {
                            self.previewMode = .empty
                        }
                    } else if result.entries.filter({ !$0.isDirectory }).isEmpty {
                        self.previewMode = .empty
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
    private func refreshPreviewOnly(relativePath: String) {
        scanTask?.cancel()
        isLoading = true
        lastError = nil
        let root = root
        let fileSystem = fileSystem
        scanTask = Task { [weak self] in
            do {
                let entry = try Self.makeEntry(
                    relativePath: relativePath,
                    root: root,
                    fileSystem: fileSystem
                )
                guard !Task.isCancelled else { return }
                await MainActor.run {
                    guard let self else { return }
                    self.entries = [entry]
                    self.truncated = false
                    self.isLoading = false
                    self.lastRefreshedAt = Date()
                    self.selectedRelativePath = relativePath
                    self.selectedPaths = [relativePath]
                    if entry.isDirectory {
                        self.clearPreview()
                        self.previewMode = .error
                        self.previewText = "Pinned path is a folder."
                        self.previewTitle = entry.name
                    } else {
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

    private static func makeEntry(relativePath: String,
                                  root: URL,
                                  fileSystem: any FileSystem) throws -> FolderFileEntry {
        let url = root.appendingPathComponent(relativePath).standardizedFileURL
        let rootPath = root.standardizedFileURL.path
        let prefix = rootPath.hasSuffix("/") ? rootPath : rootPath + "/"
        let urlPath = url.path
        guard urlPath == rootPath || urlPath.hasPrefix(prefix) else {
            throw CocoaError(.fileReadNoSuchFile)
        }
        guard fileSystem.fileExists(at: url) else {
            throw CocoaError(.fileReadNoSuchFile)
        }
        let isDir = fileSystem.isDirectory(at: url)
        let modified = (try? fileSystem.modificationDate(at: url)) ?? Date(timeIntervalSince1970: 0)
        let size = isDir ? 0 : ((try? fileSystem.byteCount(at: url)) ?? 0)
        return FolderFileEntry(
            relativePath: relativePath,
            name: url.lastPathComponent,
            fileExtension: isDir ? "" : url.pathExtension.lowercased(),
            byteCount: size,
            modifiedAt: modified,
            isDirectory: isDir
        )
    }

    func select(_ relativePath: String?) {
        selectedRelativePath = relativePath
        if let relativePath {
            selectedPaths = [relativePath]
        } else {
            selectedPaths = []
        }
        updatePreviewForSelection()
    }

    func selectMany(_ paths: Set<String>) {
        selectedPaths = paths
        // Keep multi-select intact; preview follows the primary (sorted) path.
        selectedRelativePath = paths.sorted().first
        updatePreviewForSelection()
    }

    private func updatePreviewForSelection() {
        guard let selectedRelativePath else {
            clearPreview()
            return
        }
        if kind.showsPreviewOnSelection {
            loadPreview(for: selectedRelativePath)
        } else {
            clearPreview()
        }
    }

    func clearSearchAndFilters() {
        searchText = ""
        extensionFilter = nil
        showFilters = false
        logFindText = ""
    }

    func handleEscape() -> Bool {
        if !logFindText.isEmpty {
            logFindText = ""
            return true
        }
        if !searchText.isEmpty || extensionFilter != nil || showFilters {
            clearSearchAndFilters()
            return true
        }
        if selectedRelativePath != nil || !selectedPaths.isEmpty {
            select(nil)
            return true
        }
        return false
    }

    /// Dismisses the preview pane without clearing search/filters.
    func closePreview() {
        select(nil)
    }

    func toggleSort(_ column: SortColumn) {
        if sortColumn == column {
            sortAscending.toggle()
        } else {
            sortColumn = column
            sortAscending = column != .modified && column != .size
            // Pin column defaults to pinned-first (ascending with pinned < unpinned).
            if column == .pinned {
                sortAscending = true
            }
        }
    }

    func absoluteURL(for relativePath: String) -> URL {
        root.appendingPathComponent(relativePath)
    }

    func consumePendingSelection(_ relativePath: String?) {
        guard let relativePath else { return }
        select(relativePath)
    }

    func pauseFollowFromUserScroll() {
        guard followLogs else { return }
        setFollowLogs(false)
    }

    func scrollToTOC(_ anchor: String) {
        pendingTOCAnchor = anchor
    }

    // MARK: - Preview

    private func clearPreview() {
        previewTask?.cancel()
        followTask?.cancel()
        previewGeneration += 1
        previewMode = .none
        previewText = ""
        previewCapped = false
        previewTitle = ""
        tocItems = []
        pendingTOCAnchor = nil
        logRotationNotice = nil
        logReadOffset = 0
    }

    private func loadPreview(for relativePath: String) {
        previewTask?.cancel()
        followTask?.cancel()
        previewGeneration += 1
        let generation = previewGeneration
        logRotationNotice = nil
        guard let entry = entries.first(where: { $0.relativePath == relativePath }) else {
            // Listing has not produced this row yet (scan still in flight). Keep the
            // selection and show the panel loading state until refresh finishes.
            previewMode = .none
            previewText = ""
            previewTitle = URL(fileURLWithPath: relativePath).lastPathComponent
            tocItems = []
            return
        }
        guard !entry.isDirectory else {
            clearPreview()
            return
        }
        previewTitle = entry.name
        let url = absoluteURL(for: relativePath)
        let kind = kind
        let docsShowSource = docsShowSource
        previewTask = Task { [weak self] in
            guard let self else { return }
            do {
                switch kind {
                case .files:
                    await MainActor.run {
                        guard generation == self.previewGeneration else { return }
                        self.previewMode = .none
                    }
                case .logs:
                    try await self.loadLogPreview(at: url, entry: entry, generation: generation)
                case .docs, .modelhike:
                    try await self.loadDocsPreview(at: url,
                                                   entry: entry,
                                                   showSource: docsShowSource,
                                                   generation: generation)
                }
            } catch {
                guard !Task.isCancelled else { return }
                await MainActor.run {
                    guard generation == self.previewGeneration else { return }
                    let message = error.localizedDescription
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

    private func loadLogPreview(at url: URL,
                                entry: FolderFileEntry,
                                generation: Int) async throws {
        let size = try fileSystem.byteCount(at: url)
        let offset = max(0, size - FolderBrowserLimits.logPreviewTailBytes)
        let data = try fileSystem.readData(at: url, fromOffset: offset)
        if FolderProjectScanner.isLikelyBinary(data) {
            await MainActor.run {
                guard generation == self.previewGeneration else { return }
                self.previewMode = .binary
                self.previewText = ""
                self.previewCapped = false
                self.logReadOffset = size
                self.tocItems = []
            }
            return
        }
        let text = String(data: data, encoding: .utf8)
            ?? String(decoding: data, as: UTF8.self)
        await MainActor.run {
            guard generation == self.previewGeneration else { return }
            self.previewMode = .text
            self.previewText = text
            self.previewCapped = offset > 0
            self.logReadOffset = size
            self.tocItems = []
        }
        if followLogs {
            startLogFollow(at: url, generation: generation)
        }
        _ = entry
    }

    private func loadDocsPreview(at url: URL,
                                 entry: FolderFileEntry,
                                 showSource: Bool,
                                 generation: Int) async throws {
        let size = try fileSystem.byteCount(at: url)
        if size > FolderBrowserLimits.markdownPreviewMaxBytes {
            await MainActor.run {
                guard generation == self.previewGeneration else { return }
                self.previewMode = .error
                self.previewText = "File is larger than the markdown preview limit (\(ByteCountFormatter.string(fromByteCount: Int64(FolderBrowserLimits.markdownPreviewMaxBytes), countStyle: .file)))."
                self.tocItems = []
            }
            return
        }
        let data = try fileSystem.readData(at: url)
        if FolderProjectScanner.isLikelyBinary(data) {
            await MainActor.run {
                guard generation == self.previewGeneration else { return }
                self.previewMode = .binary
                self.previewText = ""
                self.tocItems = []
            }
            return
        }
        let text = String(data: data, encoding: .utf8)
            ?? String(decoding: data, as: UTF8.self)
        let toc = MarkdownHTMLRenderer.tableOfContents(text)
        await MainActor.run {
            guard generation == self.previewGeneration else { return }
            self.previewText = text
            self.previewCapped = false
            self.tocItems = toc
            if showSource {
                self.previewMode = .source
            } else if entry.fileExtension == "md"
                        || entry.fileExtension == "markdown"
                        || kind.usesMarkdownPreview {
                self.previewMode = .markdown
            } else {
                self.previewMode = .text
                self.tocItems = []
            }
        }
    }

    func setDocsShowSource(_ showSource: Bool) {
        docsShowSource = showSource
        if let selectedRelativePath {
            loadPreview(for: selectedRelativePath)
        }
    }

    func setFollowLogs(_ follow: Bool) {
        followLogs = follow
        followTask?.cancel()
        guard follow,
              let selectedRelativePath,
              kind == .logs,
              previewMode == .text else { return }
        startLogFollow(at: absoluteURL(for: selectedRelativePath), generation: previewGeneration)
    }

    private func startLogFollow(at url: URL, generation: Int) {
        followTask?.cancel()
        followTask = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .milliseconds(750))
                guard let self, self.followLogs, generation == self.previewGeneration else { return }
                do {
                    let size = try self.fileSystem.byteCount(at: url)
                    if size < self.logReadOffset {
                        await MainActor.run {
                            guard generation == self.previewGeneration else { return }
                            self.logRotationNotice = "Log was truncated or rotated; reloaded from the end."
                            if let path = self.selectedRelativePath {
                                self.loadPreview(for: path)
                            }
                        }
                        return
                    }
                    if size > self.logReadOffset {
                        let data = try self.fileSystem.readData(at: url, fromOffset: self.logReadOffset)
                        let chunk = String(data: data, encoding: .utf8)
                            ?? String(decoding: data, as: UTF8.self)
                        await MainActor.run {
                            guard generation == self.previewGeneration else { return }
                            self.previewText.append(chunk)
                            self.logReadOffset = size
                        }
                    }
                } catch {
                    return
                }
            }
        }
    }

    // MARK: - Watching

    private func startWatching() {
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
                // Watching is best-effort; manual Refresh remains available.
            }
        }
    }
}
