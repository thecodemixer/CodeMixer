import Foundation
import Testing
@testable import AgentClientProtocol
import AgentCore
import AgentTestSupport

@Suite("ACPProjectSessionStore")
struct ACPProjectSessionStoreTests {

    @Test("paths live under project .codemixer/acp/<id>/")
    func paths() {
        let root = URL(fileURLWithPath: "/tmp/proj", isDirectory: true)
        let agent = ACPProjectPaths.agentDirectory(projectRoot: root, customAgentID: "doc-gen")
        #expect(agent.path.hasSuffix("/.codemixer/acp/doc-gen"))
        #expect(ACPProjectPaths.sessionsIndexURL(projectRoot: root, customAgentID: "doc-gen")
            .lastPathComponent == "sessions-index.json")
        #expect(ACPProjectPaths.transcriptURL(
            projectRoot: root,
            customAgentID: "doc-gen",
            sessionID: "s1"
        ).path.hasSuffix("/transcripts/s1.jsonl"))
    }

    @Test("records sessions, dual-writes JSONL, and lists summaries")
    func persistAndJSONL() async throws {
        let root = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("acp-proj-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let fs = SystemFileSystem()
        let clock = FakeClock(now: Date(timeIntervalSince1970: 1_700_000_000))
        let store = ACPProjectSessionStore(
            customAgentID: "mig",
            environment: FakeEnvironment(processEnv: [:], home: root),
            fileSystem: fs,
            clock: clock
        )

        await store.recordSession(
            id: "sess-1",
            customAgentID: "mig",
            workspace: root,
            title: nil
        )
        await store.appendConversationTurn(
            sessionID: "sess-1",
            customAgentID: "mig",
            role: "user",
            text: "migrate users"
        )
        await store.appendConversationTurn(
            sessionID: "sess-1",
            customAgentID: "mig",
            role: "assistant",
            text: "done"
        )

        let summaries = await store.summaries(workspace: root, customAgentID: "mig")
        #expect(summaries.count == 1)
        #expect(summaries[0].id == "sess-1")
        #expect(summaries[0].title == "migrate users")
        #expect(summaries[0].messageCount == 2)

        let indexURL = ACPProjectPaths.sessionsIndexURL(projectRoot: root, customAgentID: "mig")
        #expect(fs.fileExists(at: indexURL))
        let transcriptURL = ACPProjectPaths.transcriptURL(
            projectRoot: root,
            customAgentID: "mig",
            sessionID: "sess-1"
        )
        #expect(fs.fileExists(at: transcriptURL))
        let jsonl = String(decoding: try fs.readData(at: transcriptURL), as: UTF8.self)
        #expect(jsonl.contains("\"role\":\"user\""))
        #expect(jsonl.contains("migrate users"))
        #expect(jsonl.contains("\"role\":\"assistant\""))

        let events = await store.localHistoryEvents(
            sessionID: "sess-1",
            customAgentID: "mig",
            random: SystemRandomSource()
        )
        #expect(events.contains { if case .userTurn(_, let text) = $0 { return text == "migrate users" }; return false })
        #expect(events.contains {
            if case .assistantText(_, _, let text, let isFinal) = $0 {
                return text == "done" && isFinal
            }
            return false
        })
    }

    @Test("migrates matching rows from app-support index")
    func migrateFromAppSupport() async throws {
        let root = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("acp-mig-\(UUID().uuidString)", isDirectory: true)
        let home = root.appendingPathComponent("home", isDirectory: true)
        let project = root.appendingPathComponent("project", isDirectory: true)
        try FileManager.default.createDirectory(at: project, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let fs = SystemFileSystem()
        let clock = SystemClock()
        let env = FakeEnvironment(processEnv: [:], home: home)
        let legacy = ACPSessionIndex(environment: env, fileSystem: fs, clock: clock)
        await legacy.recordSession(
            id: "old-1",
            customAgentID: "mig",
            workspace: project,
            title: "legacy"
        )
        await legacy.appendConversationTurn(
            sessionID: "old-1",
            customAgentID: "mig",
            role: "user",
            text: "from app support"
        )

        let store = ACPProjectSessionStore(
            customAgentID: "mig",
            environment: env,
            fileSystem: fs,
            clock: clock
        )
        let summaries = await store.summaries(workspace: project, customAgentID: "mig")
        #expect(summaries.contains { $0.id == "old-1" })
        #expect(summaries.contains { $0.id == "old-1" && ($0.title == "legacy" || $0.title == "from app support") })
        #expect(fs.fileExists(at: ACPProjectPaths.sessionsIndexURL(
            projectRoot: project,
            customAgentID: "mig"
        )))
        #expect(fs.fileExists(at: ACPProjectPaths.transcriptURL(
            projectRoot: project,
            customAgentID: "mig",
            sessionID: "old-1"
        )))
        let events = await store.localHistoryEvents(
            sessionID: "old-1",
            customAgentID: "mig",
            random: SystemRandomSource()
        )
        #expect(events.contains {
            if case .userTurn(_, let text) = $0 { return text == "from app support" }
            return false
        })
    }

    @Test("reloads ISO-8601 index from disk into a fresh store")
    func reloadFromDisk() async throws {
        let root = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("acp-reload-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let fs = SystemFileSystem()
        let writer = ACPProjectSessionStore(
            customAgentID: "reload",
            environment: FakeEnvironment(processEnv: [:], home: root),
            fileSystem: fs,
            clock: SystemClock()
        )
        await writer.recordSession(
            id: "sess-reload",
            customAgentID: "reload",
            workspace: root,
            title: "persisted"
        )
        await writer.appendConversationTurn(
            sessionID: "sess-reload",
            customAgentID: "reload",
            role: "user",
            text: "hello disk"
        )

        let reader = ACPProjectSessionStore(
            customAgentID: "reload",
            environment: FakeEnvironment(processEnv: [:], home: root),
            fileSystem: fs,
            clock: SystemClock()
        )
        let summaries = await reader.summaries(workspace: root, customAgentID: "reload")
        #expect(summaries.contains { $0.id == "sess-reload" && $0.title == "persisted" })
        let events = await reader.localHistoryEvents(
            sessionID: "sess-reload",
            customAgentID: "reload",
            random: SystemRandomSource()
        )
        #expect(events.contains {
            if case .userTurn(_, let text) = $0 { return text == "hello disk" }
            return false
        })
    }

    @Test("trims index and JSONL to 200 turns")
    func trimsTurnsAndJSONL() async throws {
        #expect(ACPSessionStoreCodec.trimmedTurns(
            (0..<205).map { ACPConversationTurn(role: "user", text: "t\($0)") }
        ).count == 200)

        let root = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("acp-trim-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let fs = SystemFileSystem()
        let store = ACPProjectSessionStore(
            customAgentID: "trim",
            environment: FakeEnvironment(processEnv: [:], home: root),
            fileSystem: fs,
            clock: SystemClock()
        )
        await store.recordSession(
            id: "sess-trim",
            customAgentID: "trim",
            workspace: root,
            title: nil
        )
        for i in 0..<201 {
            await store.appendConversationTurn(
                sessionID: "sess-trim",
                customAgentID: "trim",
                role: i.isMultiple(of: 2) ? "user" : "assistant",
                text: "turn-\(i)"
            )
        }
        let events = await store.localHistoryEvents(
            sessionID: "sess-trim",
            customAgentID: "trim",
            random: SystemRandomSource()
        )
        #expect(events.count == 200)
        let jsonl = String(
            decoding: try fs.readData(at: ACPProjectPaths.transcriptURL(
                projectRoot: root,
                customAgentID: "trim",
                sessionID: "sess-trim"
            )),
            as: UTF8.self
        )
        let lines = jsonl.split(separator: "\n", omittingEmptySubsequences: true)
        #expect(lines.count == 200)
        #expect(jsonl.contains("turn-200"))
        #expect(!jsonl.contains("\"text\":\"turn-0\""))
    }
}
