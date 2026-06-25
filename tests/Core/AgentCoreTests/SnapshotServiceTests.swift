import Testing
import Foundation
@testable import AgentCore
import AgentTestSupport
import AgentProtocol

/// Tests for `SnapshotService` — each `SnapshotKind` must return non-empty,
/// valid UTF-8 JSON with the expected top-level keys.
@Suite("SnapshotService — per-kind JSON payload validation")
struct SnapshotServiceTests {

    @Test(".prefs snapshot contains 'appearance' and 'autoApprovalRules' keys")
    func prefsSnapshot() async throws {
        let svc = makeService()
        let data = await svc.snapshot(.prefs)
        let obj = try topLevel(data)
        #expect(obj["appearance"] != nil)
        #expect(obj["autoApprovalRules"] != nil)
    }

    @Test(".conversation snapshot contains 'messages' and 'sessionID' keys")
    func conversationSnapshot() async throws {
        let svc = makeService()
        let data = await svc.snapshot(.conversation,
                                      conversation: [("user", "hi", Date())],
                                      sessionID: "s1")
        let obj = try topLevel(data)
        #expect(obj["messages"] != nil)
        #expect(obj["sessionID"] != nil)
    }

    @Test(".diff snapshot contains 'changedFiles' key")
    func diffSnapshot() async throws {
        let svc = makeService()
        let data = await svc.snapshot(.diff, changedFiles: ["/foo.swift"])
        let obj = try topLevel(data)
        #expect(obj["changedFiles"] != nil)
    }

    @Test(".sessions snapshot contains 'recents' key")
    func sessionsSnapshot() async throws {
        let svc = makeService()
        let data = await svc.snapshot(.sessions)
        let obj = try topLevel(data)
        #expect(obj["recents"] != nil)
    }

    @Test(".workspaceTree snapshot contains 'root' and 'entries' keys")
    func workspaceTreeSnapshot() async throws {
        let svc = makeService()
        let data = await svc.snapshot(.workspaceTree)
        let obj = try topLevel(data)
        #expect(obj["root"] != nil)
        #expect(obj["entries"] != nil)
    }

    @Test("Every SnapshotKind returns non-empty, valid UTF-8 JSON")
    func allKindsProduceValidJSON() async {
        let svc = makeService()
        let allKinds: [SnapshotKind] = [.prefs, .conversation, .diff, .sessions, .workspaceTree]
        for kind in allKinds {
            let data = await svc.snapshot(kind)
            #expect(!data.isEmpty, "expected non-empty data for kind \(kind)")
            #expect(String(data: data, encoding: .utf8) != nil,
                    "expected valid UTF-8 for kind \(kind)")
            #expect((try? JSONSerialization.jsonObject(with: data)) != nil,
                    "expected valid JSON for kind \(kind)")
        }
    }

    // MARK: - Helpers

    private func makeService() -> SnapshotService {
        let env = FakeEnvironment()
        let fs  = InMemoryFileSystem()
        return SnapshotService(
            prefs: PrefsStore(environment: env, fileSystem: fs),
            sessions: SessionStore(environment: env, fileSystem: fs)
        )
    }

    /// Decode `data` as a JSON dictionary.
    private func topLevel(_ data: Data) throws -> [String: Any] {
        guard let obj = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw SnapshotTestError.notAnObject
        }
        return obj
    }

    private enum SnapshotTestError: Error { case notAnObject }
}
