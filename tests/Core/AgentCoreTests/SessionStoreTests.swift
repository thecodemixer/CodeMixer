import Testing
import Foundation
@testable import AgentCore
import AgentTestSupport

/// Tests for `SessionStore` — recency ordering, capacity cap, removal, and
/// round-trip persistence via `InMemoryFileSystem`.
@Suite("SessionStore — recency, cap, and persistence")
struct SessionStoreTests {

    @Test("recordOpen moves an existing entry to the top")
    func recordOpenMovesToTop() async throws {
        let store = makeStore()
        let clock = FakeClock()

        try await store.recordOpen(path: "/a", displayName: "A", clock: clock)
        try await store.recordOpen(path: "/b", displayName: "B", clock: clock)
        // Re-open /a — should move to position 0.
        try await store.recordOpen(path: "/a", displayName: "A", clock: clock)

        let recents = await store.recents()
        #expect(recents.first?.path == "/a")
        // /b must still be there.
        #expect(recents.contains { $0.path == "/b" })
        // No duplicates.
        #expect(recents.filter { $0.path == "/a" }.count == 1)
    }

    @Test("32-entry capacity: the 33rd insert drops the oldest entry")
    func capacityCap() async throws {
        let store = makeStore(limit: 32)
        let clock = FakeClock()

        for i in 0..<32 {
            try await store.recordOpen(path: "/p\(i)", displayName: "P\(i)", clock: clock)
        }
        // /p0 is now the oldest (at the bottom). Add one more.
        try await store.recordOpen(path: "/overflow", displayName: "Overflow", clock: clock)

        let recents = await store.recents()
        #expect(recents.count == 32)
        #expect(recents.first?.path == "/overflow")
        // /p0 was the oldest and must have been dropped.
        #expect(!recents.contains { $0.path == "/p0" })
    }

    @Test("remove(path:) removes only the matching entry")
    func removeEntry() async throws {
        let store = makeStore()
        let clock = FakeClock()

        try await store.recordOpen(path: "/x", displayName: "X", clock: clock)
        try await store.recordOpen(path: "/y", displayName: "Y", clock: clock)
        try await store.remove(path: "/x")

        let recents = await store.recents()
        #expect(!recents.contains { $0.path == "/x" })
        #expect(recents.contains { $0.path == "/y" })
    }

    @Test("Round-trip: a fresh store loading the same InMemoryFileSystem recovers the records")
    func roundTrip() async throws {
        let fs = InMemoryFileSystem()
        let env = FakeEnvironment()
        let store = SessionStore(environment: env, fileSystem: fs)
        let clock = FakeClock()

        try await store.recordOpen(path: "/proj", displayName: "MyProject",
                                   clock: clock, sessionID: "s42")

        let freshStore = SessionStore(environment: env, fileSystem: fs)
        await freshStore.load()
        let recents = await freshStore.recents()

        #expect(recents.count == 1)
        #expect(recents.first?.path == "/proj")
        #expect(recents.first?.displayName == "MyProject")
        #expect(recents.first?.lastSessionID == "s42")
    }

    @Test("internal digital twin temp workspaces are not recorded")
    func internalDigitalTwinWorkspacesAreNotRecorded() async throws {
        let store = makeStore()
        let clock = FakeClock()

        try await store.recordOpen(path: "/private/var/folders/x/T/codemixer-twin-ABC",
                                   displayName: "codemixer-twin-ABC",
                                   clock: clock)

        let recents = await store.recents()
        #expect(recents.isEmpty)
    }

    @Test("loading filters stale digital twin temp workspaces")
    func loadingFiltersStaleDigitalTwinWorkspaces() async throws {
        let fs = InMemoryFileSystem()
        let env = FakeEnvironment()
        let url = AppSupportPaths.sessionsURL(in: env.appSupportDirectory)
        try fs.createDirectory(at: url.deletingLastPathComponent(), withIntermediates: true)
        let repoPath = TestPaths.underTemporary("alice-repo").path
        let payload = """
        {
          "projects": [
            {
              "displayName": "codemixer-twin-ABC",
              "lastOpened": "2026-06-24T08:00:00Z",
              "path": "/private/var/folders/x/T/codemixer-twin-ABC"
            },
            {
              "displayName": "Repo",
              "lastOpened": "2026-06-24T07:00:00Z",
              "path": "\(repoPath)"
            }
          ]
        }
        """
        try fs.writeAtomically(Data(payload.utf8), to: url)

        let store = SessionStore(environment: env, fileSystem: fs)
        await store.load()

        let recents = await store.recents()
        #expect(recents.map(\.path) == [repoPath])
    }

    // MARK: - Helpers

    private func makeStore(limit: Int = 32) -> SessionStore {
        SessionStore(environment: FakeEnvironment(),
                     fileSystem: InMemoryFileSystem(),
                     limit: limit)
    }
}
