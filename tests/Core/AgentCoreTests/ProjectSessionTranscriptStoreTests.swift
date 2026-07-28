import Foundation
import Testing

@testable import AgentCore
import AgentTestSupport

@Suite("Project session transcript store")
struct ProjectSessionTranscriptStoreTests {
    @Test("append writes one header and preserves mutation order across batches")
    func appendPreservesMutationOrder() throws {
        let fileSystem = InMemoryFileSystem()
        let store = ProjectSessionTranscriptStore(fileSystem: fileSystem)
        let key = makeKey("append")
        let firstDate = Date(timeIntervalSince1970: 1_700_000_000)
        let secondDate = Date(timeIntervalSince1970: 1_700_000_001)
        let first = TranscriptMutation.appendUser(
            id: "user-1",
            text: "Prompt",
            recordedAt: firstDate
        )
        let second = TranscriptMutation.finalizeAssistant(
            id: "assistant-1",
            blockID: "block-1",
            text: "Reply",
            recordedAt: secondDate
        )

        try store.append([first], to: key)
        try store.append([second], to: key)

        #expect(try store.header(for: key)?.sessionID == key.sessionID)
        #expect(try store.loadMutations(for: key) == [first, second])
        #expect(fileSystem.fileExists(at: ProjectPaths.historyIgnoreURL(in: key.projectRoot)))
    }

    @Test("load ignores only an incomplete final JSONL record")
    func loadIgnoresPartialTail() throws {
        let fileSystem = InMemoryFileSystem()
        let store = ProjectSessionTranscriptStore(fileSystem: fileSystem)
        let key = makeKey("partial-tail")
        let mutation = TranscriptMutation.appendUser(
            id: "user-1",
            text: "Prompt",
            recordedAt: Date(timeIntervalSince1970: 1_700_000_000)
        )
        try store.append([mutation], to: key)
        try fileSystem.append(
            Data(#"{"mutation":{"appendUser":"#.utf8),
            to: ProjectPaths.transcriptURL(for: key)
        )

        let loaded = try store.loadMutations(for: key)

        #expect(loaded == [mutation])
    }

    @Test("write lock records its owner and can be reacquired after release")
    func writeLockLifecycle() throws {
        let fileSystem = InMemoryFileSystem()
        let store = ProjectSessionTranscriptStore(fileSystem: fileSystem)
        let key = makeKey("lock")

        let lock = try store.acquireWriteLock(for: key, ownerPID: 41)

        #expect(try store.lockOwnerPID(for: key) == 41)
        #expect(throws: FileSystemError.self) {
            try store.acquireWriteLock(for: key, ownerPID: 42)
        }

        store.releaseWriteLock(lock)
        let replacement = try store.acquireWriteLock(for: key, ownerPID: 42)
        #expect(try store.lockOwnerPID(for: key) == 42)
        store.releaseWriteLock(replacement)
    }

    @Test("load rejects a malformed record that is not the truncated tail")
    func loadRejectsMalformedMiddleRecord() throws {
        let fileSystem = InMemoryFileSystem()
        let store = ProjectSessionTranscriptStore(fileSystem: fileSystem)
        let key = makeKey("malformed-middle")
        try store.append([
            .appendUser(
                id: "user-1",
                text: "Prompt",
                recordedAt: Date(timeIntervalSince1970: 1_700_000_000)
            )
        ], to: key)
        try fileSystem.append(
            Data("not-json\n".utf8),
            to: ProjectPaths.transcriptURL(for: key)
        )

        #expect(throws: SessionTranscriptStoreError.self) {
            try store.loadMutations(for: key)
        }
    }

    private func makeKey(_ suffix: String) -> SessionTranscriptKey {
        SessionTranscriptKey(
            projectRoot: TestPaths.underTemporary("transcript-store-\(suffix)"),
            namespace: AgentID.claudeCode.rawValue,
            sessionID: "session-\(suffix)"
        )
    }
}
