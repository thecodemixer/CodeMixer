import Testing

import AgentProtocol

@Suite("AgentModelCatalogCache — snapshot and replace")
struct AgentModelCatalogCacheTests {
    @Test("snapshot returns the seeded models and replace swaps the catalog")
    func snapshotReflectsReplacement() {
        let first = AgentModelOption(code: "first", name: "First")
        let second = AgentModelOption(code: "second", name: "Second")
        let cache = AgentModelCatalogCache(models: [first])

        #expect(cache.snapshot() == [first])

        cache.replace(with: [second])

        #expect(cache.snapshot() == [second])
    }
}
