import Foundation
import Observation
import AgentCore

/// Pure layout decision for the dual folder tree surface.
enum DualFolderTreeLayout: Equatable {
    case treesOnly
    case previews

    static func resolve(left: FolderFileEntry?, right: FolderFileEntry?) -> Self {
        let leftFile = left.map { !$0.isDirectory } ?? false
        let rightFile = right.map { !$0.isDirectory } ?? false
        return (leftFile || rightFile) ? .previews : .treesOnly
    }
}

enum DualFolderTreeSide: Equatable {
    case left
    case right
    case none
}

/// Whether the compare tree mirrors the primary tree's file selection.
enum DualFolderFollowMode: Equatable {
    case independent
    case followPrimary
}

/// Outcome of the last mirror attempt. A path that exists on only one side is
/// the interesting case in a compare workflow, so it gets its own state rather
/// than collapsing into "nothing selected".
enum DualFolderFollowStatus: Equatable {
    case idle
    case mirrored(String)
    case noCounterpart(String)
}

/// Owns two independent `FolderTreeViewModel`s and the dual-surface layout.
@MainActor
@Observable
final class DualFolderTreeCoordinator {
    let primaryRoot: URL
    private(set) var secondaryRoot: URL?
    private let fileSystem: any FileSystem
    private let clock: any AgentClock

    private(set) var leftModel: FolderTreeViewModel?
    private(set) var rightModel: FolderTreeViewModel?
    var focusedSide: DualFolderTreeSide = .none
    /// Set when the secondary root is missing / unreadable so the view can recover.
    private(set) var secondaryRootError: String?
    private(set) var followMode: DualFolderFollowMode = .independent
    private(set) var followStatus: DualFolderFollowStatus = .idle

    var layout: DualFolderTreeLayout {
        DualFolderTreeLayout.resolve(
            left: leftModel?.previewedEntry,
            right: rightModel?.previewedEntry
        )
    }

    init(primaryRoot: URL,
         secondaryRoot: URL?,
         fileSystem: any FileSystem = SystemFileSystem(),
         clock: any AgentClock = SystemClock()) {
        self.primaryRoot = primaryRoot.standardizedFileURL
        self.secondaryRoot = secondaryRoot?.standardizedFileURL
        self.fileSystem = fileSystem
        self.clock = clock
    }

    func start() {
        recreateLeft()
        recreateRight()
    }

    func stop() {
        leftModel?.stop()
        rightModel?.stop()
        leftModel = nil
        rightModel = nil
    }

    func focus(_ side: DualFolderTreeSide) {
        focusedSide = side
    }

    func closePreviews() {
        leftModel?.select(nil)
        rightModel?.select(nil)
        followStatus = .idle
        focusedSide = .none
    }

    func toggleFollowMode() {
        setFollowMode(followMode == .followPrimary ? .independent : .followPrimary)
    }

    func setFollowMode(_ mode: DualFolderFollowMode) {
        guard mode != followMode else { return }
        followMode = mode
        switch mode {
        case .independent:
            followStatus = .idle
        case .followPrimary:
            syncFollowedSelection()
        }
    }

    /// Opens the primary selection's counterpart in the compare tree.
    ///
    /// Existence is checked on disk rather than against the compare tree's
    /// scanned entries: the scanner truncates very large roots, and a file the
    /// user can see on the left should still open on the right when it is
    /// there. Ancestors are expanded so the mirrored row is actually visible.
    func syncFollowedSelection() {
        guard followMode == .followPrimary, let rightModel else { return }
        guard let path = leftModel?.previewedRelativePath else {
            rightModel.select(nil)
            followStatus = .idle
            return
        }
        let counterpart = rightModel.absoluteURL(for: path)
        guard fileSystem.fileExists(at: counterpart),
              !fileSystem.isDirectory(at: counterpart) else {
            rightModel.select(nil)
            followStatus = .noCounterpart(path)
            return
        }
        rightModel.revealPath(path)
        rightModel.select(path)
        followStatus = .mirrored(path)
    }

    /// Escape in preview mode always exits previews; in trees-only it clears
    /// search/filters on the focused side.
    @discardableResult
    func handleEscape() -> Bool {
        if layout == .previews {
            closePreviews()
            return true
        }
        switch focusedSide {
        case .left:
            return leftModel?.handleEscape() ?? false
        case .right:
            return rightModel?.handleEscape() ?? false
        case .none:
            if leftModel?.handleEscape() == true { return true }
            return rightModel?.handleEscape() ?? false
        }
    }

    /// Project-title reselection: clear previews and filters on both sides.
    func resetForProjectOverview() {
        leftModel?.clearSearchAndFilters()
        rightModel?.clearSearchAndFilters()
        closePreviews()
    }

    /// Replace the secondary root after the user recovers from a missing folder.
    /// Returns a user-facing error string on failure.
    @discardableResult
    func replaceSecondaryRoot(_ url: URL) -> String? {
        do {
            let validated = try ProjectLocalStateStore.validateSecondaryRoot(
                url,
                primaryRoot: primaryRoot,
                fileSystem: fileSystem
            )
            _ = try ProjectLocalStateStore.updateSecondaryRootPath(
                validated,
                in: primaryRoot,
                fileSystem: fileSystem
            )
            secondaryRoot = validated
            secondaryRootError = nil
            recreateRight()
            closePreviews()
            return nil
        } catch {
            secondaryRootError = error.localizedDescription
            return secondaryRootError
        }
    }

    private func recreateLeft() {
        leftModel?.stop()
        let created = FolderTreeViewModel(
            root: primaryRoot,
            fileSystem: fileSystem,
            clock: clock
        )
        leftModel = created
        created.start()
    }

    private func recreateRight() {
        rightModel?.stop()
        rightModel = nil
        secondaryRootError = nil
        guard let secondaryRoot else {
            secondaryRootError = "Choose a compare folder to browse beside the project."
            return
        }
        guard fileSystem.isDirectory(at: secondaryRoot) else {
            secondaryRootError = "Compare folder is missing or unreadable: \(secondaryRoot.path)"
            return
        }
        let created = FolderTreeViewModel(
            root: secondaryRoot,
            fileSystem: fileSystem,
            clock: clock
        )
        rightModel = created
        created.start()
    }
}
