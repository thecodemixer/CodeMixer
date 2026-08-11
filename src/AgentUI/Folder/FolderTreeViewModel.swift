import Foundation
import Observation
import AgentCore

/// Ephemeral state for one `FolderProjectKind.folderTree` project.
/// Preferences are not persisted — only kind + pins live in project.json.
@MainActor
@Observable
final class FolderTreeViewModel {
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
    let fileSystem: any FileSystem
    let clock: any AgentClock

    var entries: [FolderFileEntry] = []
    var truncated = false
    var searchText = ""
    var extensionFilter: String?
    var showFilters = false
    var selectedRelativePath: String?
    /// Paths currently pinned in the sidebar.
    var pinnedRelativePaths: Set<String> = []
    /// Directory relative paths the user has expanded (filter does not mutate this).
    var expandedPaths: Set<String> = []
    var isLoading = false
    var lastError: String?
    var previewMode: PreviewMode = .none
    var previewText = ""
    var previewCapped = false
    var previewTitle = ""
    var docsShowSource = false
    var lineWrap = true
    var lastRefreshedAt: Date?

    /// When true, skip directory enumeration and only keep the selected file warm.
    private(set) var isPreviewOnlyListing = false

    var treeRoots: [FolderTreeNode] = []

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
