import Foundation
import Testing
@testable import AgentCore

@Suite("ChangedFilesReconciler")
struct ChangedFilesReconcilerTests {

    @Test("reconcile reports added and removed paths")
    func reconcileDelta() {
        let current = ["a.swift", "b.swift"]
        let git = ["b.swift", "c.swift"]
        let delta = ChangedFilesReconciler.reconcile(current: current, gitPaths: git)
        #expect(delta.added == ["c.swift"])
        #expect(delta.removed == ["a.swift"])
        #expect(delta.next == ["b.swift", "c.swift"])
    }

    @Test("reconcile with identical sets yields empty deltas")
    func reconcileNoOp() {
        let paths = ["src/App.swift", "src/Util.swift"]
        let delta = ChangedFilesReconciler.reconcile(current: paths, gitPaths: paths)
        #expect(delta.added.isEmpty)
        #expect(delta.removed.isEmpty)
        #expect(delta.next == paths.sorted())
    }
}
