import Foundation

/// Pure helper for syncing engine `changedFiles` against `git status --porcelain`.
enum ChangedFilesReconciler {
    static func reconcile(current: [String], gitPaths: [String])
        -> (added: [String], removed: [String], next: [String]) {
        let previous = Set(current)
        let nextSet = Set(gitPaths)
        let added = nextSet.subtracting(previous).sorted()
        let removed = previous.subtracting(nextSet).sorted()
        return (added, removed, gitPaths.sorted())
    }
}
