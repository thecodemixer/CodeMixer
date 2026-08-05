import Foundation
import Testing

@testable import AgentCore
import AgentTestSupport

@Suite("Session transcript repository")
struct SessionTranscriptRepositoryTests {
    @Test("recorded history and session index survive repository recreation")
    func historyAndIndexSurviveRecreation() async throws {
        let fileSystem = InMemoryFileSystem()
        let clock = FakeClock(now: Date(timeIntervalSince1970: 1_700_000_000))
        let key = makeKey("recreation")
        let first = makeRepository(fileSystem: fileSystem, clock: clock, ownerPID: 101)
        try await first.record(.userTurn(id: "user-1", text: "Persistent prompt"),
                               for: key)
        clock.advance(by: .seconds(1))
        try await first.record(.assistantText(id: "assistant-1",
                                              blockID: "block-1",
                                              text: "Persistent reply",
                                              isFinal: true),
                               for: key)

        let listed = try await first.sessions(inProject: key.projectRoot)
        #expect(listed.first?.id == key.sessionID)
        #expect(listed.first?.title == "Persistent prompt")
        #expect(listed.first?.messageCount == 1)
        try await first.shutdown()

        let second = makeRepository(fileSystem: fileSystem, clock: clock, ownerPID: 102)
        let replay = try await second.replayEvents(for: key)

        #expect(replay.contains {
            if case .userTurn(_, let text) = $0 { return text == "Persistent prompt" }
            return false
        })
        #expect(replay.contains {
            if case .assistantText(_, _, let text, true) = $0 {
                return text == "Persistent reply"
            }
            return false
        })
        try await second.shutdown()
    }

    @Test("edit truncation and replacement persist the revised user turn")
    func editReplacementPersistsAcrossReload() async throws {
        let fileSystem = InMemoryFileSystem()
        let clock = FakeClock()
        let key = makeKey("truncate")
        let first = makeRepository(fileSystem: fileSystem, clock: clock, ownerPID: 201)
        try await first.record([
            .userTurn(id: "user-1", text: "First"),
            .assistantText(id: "assistant-1",
                           blockID: "block-1",
                           text: "Reply",
                           isFinal: true),
            .userTurn(id: "user-2", text: "Second")
        ], for: key)

        try await first.truncate(afterUserTurnID: "user-1", for: key)
        try await first.replaceUserTurn(id: "user-1", text: "Revised", for: key)
        try await first.shutdown()

        let second = makeRepository(fileSystem: fileSystem, clock: clock, ownerPID: 202)
        let transcript = try await second.transcript(for: key)
        #expect(transcript.snapshotMessages().map(\.text) == ["Revised"])
        try await second.shutdown()
    }

    @Test("live lock owner makes a second repository read-only")
    func liveLockOwnerRejectsSecondWriter() async throws {
        let fileSystem = InMemoryFileSystem()
        let clock = FakeClock()
        let key = makeKey("locked")
        let first = makeRepository(
            fileSystem: fileSystem,
            clock: clock,
            ownerPID: 301
        ) { $0 == 301 }
        _ = try await first.transcript(for: key)
        let second = makeRepository(
            fileSystem: fileSystem,
            clock: clock,
            ownerPID: 302
        ) { $0 == 301 }
        _ = try await second.transcript(for: key)

        do {
            try await second.record(.userTurn(id: "user-1", text: "Blocked"),
                                    for: key)
            Issue.record("Expected locked repository error")
        } catch let error as SessionTranscriptRepositoryError {
            #expect(error == .locked(sessionID: key.sessionID, ownerPID: 301))
        }

        try await second.shutdown()
        try await first.shutdown()
    }

    @Test("corrupt index rebuilds from transcript journals")
    func corruptIndexRebuildsFromJournals() throws {
        let fileSystem = InMemoryFileSystem()
        let store = ProjectSessionTranscriptStore(fileSystem: fileSystem)
        let key = makeKey("rebuild")
        let recordedAt = Date(timeIntervalSince1970: 1_700_000_000)
        try store.append([
            .appendUser(id: "user-1", text: "Recovered title", recordedAt: recordedAt),
            .appendUser(id: "user-2", text: "Follow-up", recordedAt: recordedAt)
        ], to: key)
        try fileSystem.writeAtomically(
            Data("invalid index".utf8),
            to: ProjectPaths.historyIndexURL(in: key.projectRoot)
        )

        let records = try store.loadIndex(in: key.projectRoot)

        #expect(records.first?.sessionID == key.sessionID)
        #expect(records.first?.title == "Recovered title")
        #expect(records.first?.userTurnCount == 2)
    }

    @Test("session listing overlays transient attention without persisting it")
    func sessionListingOverlaysAttention() async throws {
        let fileSystem = InMemoryFileSystem()
        let clock = FakeClock()
        let key = makeKey("attention")
        let repository = makeRepository(
            fileSystem: fileSystem,
            clock: clock,
            ownerPID: 401
        )
        try await repository.registerSession(
            key.sessionID,
            namespace: key.namespace,
            agentID: .codex,
            in: key.projectRoot
        )

        let attentive = try await repository.sessions(
            inProject: key.projectRoot,
            attentionSessionIDs: [key.sessionID]
        )
        let ordinary = try await repository.sessions(inProject: key.projectRoot)

        #expect(attentive.first?.needsAttention == true)
        #expect(ordinary.first?.needsAttention == false)
        try await repository.shutdown()
    }

    @Test("archiving a session is carried on the listed summary and reversible")
    func archivedFlagRoundTripsThroughSessionListing() async throws {
        let fileSystem = InMemoryFileSystem()
        let clock = FakeClock()
        let key = makeKey("archived")
        let repository = makeRepository(
            fileSystem: fileSystem,
            clock: clock,
            ownerPID: 402
        )
        try await repository.registerSession(
            key.sessionID,
            namespace: key.namespace,
            agentID: .other,
            in: key.projectRoot
        )

        try await repository.markArchived(key.sessionID, archived: true, in: key.projectRoot)
        let archived = try await repository.sessions(
            inProject: key.projectRoot,
            attentionSessionIDs: [key.sessionID]
        )
        #expect(archived.first?.archived == true)
        // An archived row must not keep pulling the navigator's attention badge.
        #expect(archived.first?.needsAttention == false)

        try await repository.markArchived(key.sessionID, archived: false, in: key.projectRoot)
        let restored = try await repository.sessions(inProject: key.projectRoot)
        #expect(restored.first?.archived == false)
        try await repository.shutdown()
    }

    @Test("large imported catalogs remain ordered and replay complete session histories")
    func largeCatalogImportRemainsOrdered() async throws {
        let sessionCount = 250
        let turnsPerSession = 12
        let fileSystem = InMemoryFileSystem()
        let clock = FakeClock(now: Date(timeIntervalSince1970: 1_700_000_000))
        let root = TestPaths.underTemporary("transcript-repository-large-import")
        let repository = makeRepository(
            fileSystem: fileSystem,
            clock: clock,
            ownerPID: 501
        )
        let sessions = (0 ..< sessionCount).map { sessionIndex in
            ImportedSession(
                id: "session-\(sessionIndex)",
                title: "Session \(sessionIndex)",
                lastActivity: clock.now().addingTimeInterval(Double(sessionIndex)),
                events: (0 ..< turnsPerSession).flatMap { turnIndex in
                    [
                        AgentEvent.userTurn(
                            id: "user-\(sessionIndex)-\(turnIndex)",
                            text: "Prompt \(sessionIndex)-\(turnIndex)"
                        ),
                        .assistantText(
                            id: "assistant-\(sessionIndex)-\(turnIndex)",
                            blockID: "block-\(sessionIndex)-\(turnIndex)",
                            text: "Reply \(sessionIndex)-\(turnIndex)",
                            isFinal: true
                        ),
                    ]
                }
            )
        }

        try await repository.importCatalog(
            sessions,
            namespace: AgentID.claudeCode.rawValue,
            agentID: .claudeCode,
            into: root
        )

        let listed = try await repository.sessions(inProject: root)
        #expect(listed.count == sessionCount)
        #expect(listed.first?.id == "session-\(sessionCount - 1)")
        #expect(listed.last?.id == "session-0")
        #expect(listed.first?.messageCount == turnsPerSession)

        let latestKey = SessionTranscriptKey(
            projectRoot: root,
            namespace: AgentID.claudeCode.rawValue,
            sessionID: "session-\(sessionCount - 1)"
        )
        let replay = try await repository.replayEvents(for: latestKey)
        #expect(replay.count == turnsPerSession * 2)
        #expect(replay.contains {
            if case .userTurn(_, "Prompt 249-11") = $0 { return true }
            return false
        })
        try await repository.shutdown()
    }

    private func makeRepository(
        fileSystem: InMemoryFileSystem,
        clock: FakeClock,
        ownerPID: Int32,
        processIsRunning: @escaping @Sendable (Int32) -> Bool = { _ in false }
    ) -> SessionTranscriptRepository {
        SessionTranscriptRepository(
            store: ProjectSessionTranscriptStore(fileSystem: fileSystem),
            clock: clock,
            ownerPID: ownerPID,
            processIsRunning: processIsRunning
        )
    }

    private func makeKey(_ suffix: String) -> SessionTranscriptKey {
        SessionTranscriptKey(
            projectRoot: TestPaths.underTemporary("transcript-repository-\(suffix)"),
            namespace: AgentID.codex.rawValue,
            sessionID: "session-\(suffix)"
        )
    }
}
