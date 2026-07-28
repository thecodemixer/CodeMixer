import Foundation
import Testing

@testable import AgentCore
import AgentProtocol
import AgentTestSupport

@Suite("Session transcript aggregation")
struct SessionTranscriptTests {
    @Test("semantic mutations coalesce streaming blocks and replay completed work")
    func mutationsAggregateReplayableBlocks() {
        let key = SessionTranscriptKey(
            projectRoot: TestPaths.underTemporary("transcript-aggregate"),
            namespace: AgentID.claudeCode.rawValue,
            sessionID: "session-1"
        )
        let recordedAt = Date(timeIntervalSince1970: 1_700_000_000)
        let thinkingID = UUID(uuidString: "00000000-0000-0000-0000-000000000010")!
        let toolID = "00000000-0000-0000-0000-000000000020"
        var transcript = SessionTranscript(key: key)

        transcript.apply(.appendUser(id: "user-1", text: "Prompt", recordedAt: recordedAt))
        transcript.apply(.appendUser(id: "user-1", text: "Prompt", recordedAt: recordedAt))
        transcript.apply(.appendThinking(blockID: thinkingID,
                                         delta: "Plan ",
                                         recordedAt: recordedAt))
        transcript.apply(.appendThinking(blockID: thinkingID,
                                         delta: "steps",
                                         recordedAt: recordedAt))
        transcript.apply(.completeThinking(blockID: thinkingID,
                                           durationMS: 25,
                                           recordedAt: recordedAt))
        transcript.apply(.startTool(id: toolID,
                                    name: "Read",
                                    input: ToolInput(summary: "README.md"),
                                    startedAt: recordedAt))
        transcript.apply(.updateTool(id: toolID,
                                     progress: .generic(message: "reading"),
                                     recordedAt: recordedAt))
        transcript.apply(.finishTool(id: toolID,
                                     success: true,
                                     output: ToolOutput(summary: "done"),
                                     durationMS: 5,
                                     recordedAt: recordedAt))
        transcript.apply(.finalizeAssistant(id: "assistant-1",
                                            blockID: "block-1",
                                            text: "Reply",
                                            recordedAt: recordedAt))

        #expect(transcript.entries.count == 4)
        #expect(transcript.replayEvents().contains {
            if case .thinkingChunk(let id, let delta) = $0 {
                return id == thinkingID && delta == "Plan steps"
            }
            return false
        })
        #expect(transcript.replayEvents().contains {
            if case .toolEnd(let id, true, let output, 5) = $0 {
                return id == toolID && output.summary == "done"
            }
            return false
        })
    }

    @Test("truncate removes every block after the selected user turn")
    func truncationRemovesLaterBlocks() {
        let key = SessionTranscriptKey(
            projectRoot: TestPaths.underTemporary("transcript-truncate"),
            namespace: AgentID.codex.rawValue,
            sessionID: "session-2"
        )
        let recordedAt = Date(timeIntervalSince1970: 1_700_000_000)
        var transcript = SessionTranscript(key: key)
        transcript.apply(.appendUser(id: "user-1", text: "First", recordedAt: recordedAt))
        transcript.apply(.finalizeAssistant(id: "assistant-1",
                                            blockID: "block-1",
                                            text: "Reply",
                                            recordedAt: recordedAt))
        transcript.apply(.appendUser(id: "user-2", text: "Second", recordedAt: recordedAt))

        transcript.truncate(afterUserTurnID: "user-1")

        #expect(transcript.entries.count == 1)
        #expect(transcript.snapshotMessages().map(\.text) == ["First"])
    }

    @Test("phase, client action, and changed files remain ordered domain state")
    func peripheralStateBelongsToTranscript() {
        let root = TestPaths.underTemporary("transcript-peripheral-state")
        let key = SessionTranscriptKey(
            projectRoot: root,
            namespace: AgentID.cursorCLI.rawValue,
            sessionID: "session-3"
        )
        let recordedAt = Date(timeIntervalSince1970: 1_700_000_000)
        let file = ChangedFile(
            url: root.appendingPathComponent("Sources/App.swift"),
            workspace: root
        )
        let phase = SessionPhase(
            id: "reviewing",
            label: "Review",
            ordinal: 2,
            group: .review
        )
        let action = ClientAction(
            id: UUID(uuidString: "00000000-0000-0000-0000-000000000030")!,
            kind: .mode,
            title: "Review mode"
        )
        var transcript = SessionTranscript(key: key)

        transcript.apply(.touchFile(file: file, kind: .fsObserved, recordedAt: recordedAt))
        transcript.apply(.changePhase(
            sessionID: key.sessionID,
            phase: phase,
            recordedAt: recordedAt
        ))
        transcript.apply(.appendClientAction(action, recordedAt: recordedAt))

        #expect(transcript.changedFiles == [file])
        #expect(transcript.replayEvents().contains {
            if case .sessionPhaseChanged(let id, let replayed) = $0 {
                return id == key.sessionID && replayed == phase
            }
            return false
        })
        #expect(transcript.snapshotMessages().contains {
            $0.role == .action && $0.text == action.title
        })
    }

    @Test("replay is bounded without discarding durable entries")
    func replayUsesTheMostRecentBoundedWindow() {
        let key = SessionTranscriptKey(
            projectRoot: TestPaths.underTemporary("transcript-replay-bound"),
            namespace: AgentID.claudeCode.rawValue,
            sessionID: "session-4"
        )
        let recordedAt = Date(timeIntervalSince1970: 1_700_000_000)
        var transcript = SessionTranscript(key: key)
        for index in 0 ... SessionTranscript.replayEntryLimit {
            transcript.apply(.appendUser(
                id: "user-\(index)",
                text: "Prompt \(index)",
                recordedAt: recordedAt
            ))
        }

        #expect(transcript.entries.count == SessionTranscript.replayEntryLimit + 1)
        #expect(transcript.truncatedEntryCount == 1)
        #expect(transcript.snapshotMessages().first?.text == "Prompt 1")
    }
}
