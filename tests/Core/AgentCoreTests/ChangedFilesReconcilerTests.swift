import Foundation
import Testing
@testable import AgentCore

@Suite("ChangedFilesReconciler")
struct ChangedFilesReconcilerTests {

    @Test("reconcile reports added and removed paths")
    func reconcileDelta() {
        let current = [
            ChangedFile(relativePath: "a.swift"),
            ChangedFile(relativePath: "b.swift"),
        ]
        let git = [
            ChangedFile(relativePath: "b.swift"),
            ChangedFile(relativePath: "c.swift"),
        ]
        let delta = ChangedFilesReconciler.reconcile(current: current, gitPaths: git)
        #expect(delta.added.map(\.relativePath) == ["c.swift"])
        #expect(delta.removed.map(\.relativePath) == ["a.swift"])
        #expect(delta.next.map(\.relativePath) == ["b.swift", "c.swift"])
    }

    @Test("reconcile with identical sets yields empty deltas")
    func reconcileNoOp() {
        let paths = [
            ChangedFile(relativePath: "src/App.swift"),
            ChangedFile(relativePath: "src/Util.swift"),
        ]
        let delta = ChangedFilesReconciler.reconcile(current: paths, gitPaths: paths)
        #expect(delta.added.isEmpty)
        #expect(delta.removed.isEmpty)
        #expect(delta.next.map(\.relativePath) == ["src/App.swift", "src/Util.swift"])
    }
}
