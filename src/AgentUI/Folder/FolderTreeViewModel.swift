import Foundation
import Observation
import AgentCore

/// Ephemeral state for one `FolderProjectKind.folderTree` project.
/// Preferences are not persisted — only kind + pins live in project.json.
@MainActor
@Observable
final class FolderTreeViewModel {
    let root: URL
    let fileSystem: any FileSystem
    let clock: any AgentClock

    var entries: [FolderFileEntry] = []
    var truncated = false
    /// Filtering is cached rather than recomputed per access: the outline asks
    /// each directory row whether it is expanded, and recomputing the pruned
    /// tree per row made a single click cost seconds on a large project.
    var searchText: String {
        get { searchTextStorage }
        set {
            guard newValue != searchTextStorage else { return }
            searchTextStorage = newValue
            rebuildVisibleTree()
        }
    }

    var extensionFilter: String? {
        get { extensionFilterStorage }
        set {
            guard newValue != extensionFilterStorage else { return }
            extensionFilterStorage = newValue
            rebuildVisibleTree()
        }
    }

    private var searchTextStorage = ""
    private var extensionFilterStorage: String?
    var showFilters = false
    /// The highlighted outline row. May be a file or a directory — clicking a
    /// directory to expand it selects the row without disturbing the preview.
    var selectedRelativePath: String?
    /// The file whose contents fill the preview pane. Only ever a file, and
    /// deliberately independent of `selectedRelativePath` so navigating folders
    /// keeps the open file on screen until another file is chosen or Escape
    /// closes it. Mutated only through `select(_:)` and refresh reconciliation.
    var previewedRelativePath: String?
    /// Paths currently pinned in the sidebar.
    var pinnedRelativePaths: Set<String> = []
    /// Directory relative paths the user has expanded (filter does not mutate this).
    var expandedPaths: Set<String> = []
    var isLoading = false
    var lastError: String?
    var previewMode: FilePreviewMode = .none
    var previewText = ""
    var previewCapped = false
    var previewTitle = ""
    var docsShowSource = false
    var lineWrap = true
    var lastRefreshedAt: Date?

    /// When true, skip directory enumeration and only keep the selected file warm.
    private(set) var isPreviewOnlyListing = false

    var treeRoots: [FolderTreeNode] = []

    /// Derived from `treeRoots` + the filter by `rebuildVisibleTree()`; never
    /// assigned anywhere else.
    var visibleTreeRoots: [FolderTreeNode] = []
    /// Directories the active filter forces open, without touching `expandedPaths`.
    var filterExpandedPaths: Set<String> = []

    /// Last row activation, used to absorb the second click of a double click.
    var lastActivatedPath: String?
    var lastActivatedAt: Date?

    var scanTask: Task<Void, Never>?
    var previewTask: Task<Void, Never>?
    var watcher: FSEventsWatcher?
    var watchTask: Task<Void, Never>?
    var previewGeneration = 0

    init(root: URL,
         fileSystem: any FileSystem = SystemFileSystem(),
         clock: any AgentClock = SystemClock(),
         initialRelativePath: String? = nil) {
        self.root = root.standardizedFileURL
        self.fileSystem = fileSystem
        self.clock = clock
        self.selectedRelativePath = initialRelativePath
        self.previewedRelativePath = initialRelativePath
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

    var directoryCount: Int {
        entries.filter(\.isDirectory).count
    }

    var selectedEntry: FolderFileEntry? {
        guard let selectedRelativePath else { return nil }
        return entries.first { $0.relativePath == selectedRelativePath }
    }

    var previewedEntry: FolderFileEntry? {
        guard let previewedRelativePath else { return nil }
        return entries.first { $0.relativePath == previewedRelativePath }
    }

    /// True when a file preview is open, regardless of which row is highlighted.
    var isPreviewingFile: Bool {
        previewedRelativePath != nil
    }

    var isEmptyListing: Bool {
        !isLoading && lastError == nil && entries.isEmpty
    }

    var hasActiveFilter: Bool {
        !searchText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            || extensionFilter != nil
    }

    func absoluteURL(for relativePath: String) -> URL {
        root.appendingPathComponent(relativePath)
    }

    func start(previewOnly: Bool = false) {
        if previewOnly, let path = selectedRelativePath {
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
        watchTask?.cancel()
        Task { await watcher?.stop() }
        watcher = nil
    }

    func consumePendingSelection(_ relativePath: String?) {
        guard let relativePath else { return }
        select(relativePath)
    }

    func closePreview() {
        select(nil)
    }
}
