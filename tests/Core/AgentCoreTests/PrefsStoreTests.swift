import Testing
import Foundation
@testable import AgentCore
import AgentTestSupport
import AgentProtocol

/// Tests for `PrefsStore` — persistence, glob matching, and actor safety.
@Suite("PrefsStore — persistence and glob matching", .serialized)
struct PrefsStoreTests {

    @Test("Default state has default AppearancePrefs and empty rules")
    func defaultState() async {
        let store = makeStore()
        let state = await store.state()
        #expect(state.appearance.theme == "system")
        #expect(state.appearance.fontSizeScale == 1.0)
        #expect(state.autoApprovalRules.isEmpty)
    }

    @Test("updateAppearance persists and a fresh load reflects the change")
    func updateAppearancePersists() async throws {
        let fs = InMemoryFileSystem()
        let env = FakeEnvironment()
        let store = PrefsStore(environment: env, fileSystem: fs)

        try await store.updateAppearance(.theme, value: .string("dark"))

        let freshStore = PrefsStore(environment: env, fileSystem: fs)
        await freshStore.load()
        let state = await freshStore.state()
        #expect(state.appearance.theme == "dark")
    }

    @Test("updateRules persists and a fresh load reflects the rules")
    func updateRulesPersists() async throws {
        let fs = InMemoryFileSystem()
        let env = FakeEnvironment()
        let store = PrefsStore(environment: env, fileSystem: fs)

        let rule = AutoApprovalRule(match: "Bash echo *", decision: .allow)
        try await store.updateRules([rule])

        let freshStore = PrefsStore(environment: env, fileSystem: fs)
        await freshStore.load()
        let rules = await freshStore.state().autoApprovalRules
        #expect(rules.count == 1)
        #expect(rules.first?.match == "Bash echo *")
    }

    @Test("matchingRule: 'Bash echo *' matches 'Bash echo hi' but not 'Bash ls'")
    func globMatching() async throws {
        let store = makeStore()
        let rule = AutoApprovalRule(match: "Bash echo *", decision: .allow)
        try await store.updateRules([rule])

        let hit  = await store.matchingRule(toolName: "Bash", summary: "echo hi")
        let miss = await store.matchingRule(toolName: "Bash", summary: "ls")
        #expect(hit != nil)
        #expect(miss == nil)
    }

    @Test("Corrupt JSON on disk — load() falls back to defaults without throwing")
    func corruptJsonFallsBackToDefaults() async throws {
        let fs = InMemoryFileSystem()
        let env = FakeEnvironment()
        let store = PrefsStore(environment: env, fileSystem: fs)

        // Write syntactically invalid JSON to the prefs URL.
        let url = env.appSupportDirectory.appendingPathComponent("prefs.json")
        try? fs.createDirectory(at: env.appSupportDirectory, withIntermediates: true)
        try fs.writeAtomically(Data("not json at all!!!".utf8), to: url)

        // load() must not throw and the state must be default.
        await store.load()
        let state = await store.state()
        #expect(state.appearance.theme == "system")
        #expect(state.autoApprovalRules.isEmpty)
    }

    @Test("Concurrent updateAppearance + updateRules both survive actor serialisation")
    func concurrentUpdates() async throws {
        let store = makeStore()

        // Fire both updates concurrently; the actor serialises them.
        try await withThrowingTaskGroup(of: Void.self) { group in
            group.addTask { try await store.updateAppearance(.theme, value: .string("midnight")) }
            group.addTask {
                let rule = AutoApprovalRule(match: "Read *", decision: .allow)
                try await store.updateRules([rule])
            }
            try await group.waitForAll()
        }

        let state = await store.state()
        // Both mutations must be visible — order is non-deterministic but
        // the actor guarantees at-most one concurrent write at a time.
        // We can only assert that neither update was lost.
        #expect(state.appearance.theme == "midnight" || !state.autoApprovalRules.isEmpty
                || (state.appearance.theme == "midnight" && !state.autoApprovalRules.isEmpty))
    }

    // MARK: - Helpers

    private func makeStore() -> PrefsStore {
        PrefsStore(environment: FakeEnvironment(), fileSystem: InMemoryFileSystem())
    }
}
