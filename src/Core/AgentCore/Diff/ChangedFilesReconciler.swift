import Foundation
import AgentProtocol

/// Pure helper for syncing engine `changedFiles` against `git status --porcelain`.
enum ChangedFilesReconciler {
    static func reconcile(current: [ChangedFile], gitPaths: [ChangedFile])
        -> (added: [ChangedFile], removed: [ChangedFile], next: [ChangedFile]) {
        let previous = Set(current)
        let nextSet = Set(gitPaths)
        let added = nextSet.subtracting(previous).sorted { $0.relativePath < $1.relativePath }
        let removed = previous.subtracting(nextSet).sorted { $0.relativePath < $1.relativePath }
        let next = gitPaths.sorted { $0.relativePath < $1.relativePath }
        return (added, removed, next)
    }
}
