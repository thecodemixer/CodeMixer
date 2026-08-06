@testable import AgentClientProtocol
@testable import AgentCore
import AgentProtocol
import AgentTestSupport
import Foundation
import Testing

/// New Chat keeps the ACP process and only rebinds the session id, so the
/// previous session's in-flight frames keep arriving on the same wire. None of
/// them may reach the new chat: neither while the client awaits `session/new`,
/// nor after the replacement id is bound.
@Suite("ACP new-session isolation")
struct ACPNewSessionIsolationTests {

    @Test("Chunks in flight when New Chat is issued never reach the replacement session")
    func lateChunksFromPreviousSessionStayOut() async throws {
        let harness = Harness()
        harness.state.setSessionID("s1")

        let live = await harness.decoder.decode(harness.chunk(session: "s1", text: "old-session-text"))
        #expect(!live.events.isEmpty)

        // What `ACPAdapter.encodeCommand(.newSession)` does before writing
        // `session/new`: drop the bound id and await the replacement.
        harness.state.prepareNewSession()

        let whileAwaiting = await harness.decoder.decode(harness.chunk(session: "s1", text: "old-tail-while-awaiting"))
        #expect(whileAwaiting.events.isEmpty)

        harness.state.setSessionID("s2")

        let afterRebind = await harness.decoder.decode(harness.chunk(session: "s1", text: "old-tail-after-rebind"))
        #expect(afterRebind.events.isEmpty)

        let promptID = harness.state.nextRequestID(for: .sessionPrompt)
        _ = await harness.decoder.decode(harness.chunk(session: "s2", text: "new-session-text"))
        let finalized = await harness.decoder.decode(.response(id: promptID,
                                                               result: .object(["stopReason": .string("end_turn")]),
                                                               error: nil))

        let assistant = finalized.events.compactMap { event -> String? in
            if case .assistantText(_, _, let text, true) = event { return text }
            return nil
        }
        #expect(assistant == ["new-session-text"])
    }

    @Test("A previous session's late chunk is persisted as that session's history")
    func lateChunksFromPreviousSessionAreRecordedInBackground() async throws {
        let recorder = BackgroundRecorder()
        let harness = Harness { batch in await recorder.append(batch) }
        harness.state.setSessionID("s1")
        harness.state.prepareNewSession()
        harness.state.setSessionID("s2")

        _ = await harness.decoder.decode(harness.chunk(session: "s1", text: "old-tail"))
        // A chunk is only flushed to history when the sender's role changes or
        // the stream ends; a user chunk closes the preceding agent run.
        _ = await harness.decoder.decode(harness.chunk(session: "s1", text: "next", kind: "user_message_chunk"))

        let recorded = await recorder.batches
        #expect(recorded.allSatisfy { $0.sessionID == "s1" })
        #expect(recorded.contains { batch in
            batch.events.contains { event in
                if case .assistantText(_, _, let text, _) = event { return text == "old-tail" }
                return false
            }
        })
    }

    @Test("A background session's mode and model updates do not retarget the foreground chat")
    func foreignModeAndModelUpdatesAreIgnored() async throws {
        let harness = Harness()
        harness.state.setSessionID("s2")
        _ = await harness.decoder.decode(harness.modeUpdate(session: "s2", modeID: "plan"))
        _ = await harness.decoder.decode(harness.modelUpdate(session: "s2", modelID: "fast"))

        let foreignMode = await harness.decoder.decode(harness.modeUpdate(session: "s1", modeID: "ask"))
        _ = await harness.decoder.decode(harness.modelUpdate(session: "s1", modelID: "slow"))

        #expect(foreignMode.events.isEmpty)
        #expect(harness.state.currentModeID() == "plan")
        #expect(harness.state.currentModelID() == "fast")
    }

    @Test("Mode and model updates for the foreground session still apply")
    func foregroundModeAndModelUpdatesApply() async throws {
        let harness = Harness()
        harness.state.setSessionID("s2")

        let mode = await harness.decoder.decode(harness.modeUpdate(session: "s2", modeID: "plan"))
        _ = await harness.decoder.decode(harness.modelUpdate(session: "s2", modelID: "fast"))

        #expect(mode.events.contains { event in
            if case .statusPhraseChanged(_, let phrase) = event { return phrase == "Mode: plan" }
            return false
        })
        #expect(harness.state.currentModeID() == "plan")
        #expect(harness.state.currentModelID() == "fast")
    }

    private actor BackgroundRecorder {
        private(set) var batches: [BackgroundSessionEventBatch] = []

        func append(_ batch: BackgroundSessionEventBatch) {
            batches.append(batch)
        }
    }

    private struct Harness {
        let state = ACPClientState()
        let decoder: ACPEventDecoder

        init(recordBackground: @escaping @Sendable (BackgroundSessionEventBatch) async -> Void = { _ in }) {
            let workspace = TestPaths.underTemporary("acp-new-session-ws")
            let random = SystemRandomSource()
            _ = ACPInputEncoding.bootstrap(context: LaunchContext(workspace: workspace, permissionMode: .default),
                                           state: state,
                                           customAgentID: "x",
                                           displayName: "Test Agent")
            decoder = ACPEventDecoder(state: state,
                                      fileAccess: ACPFileAccess(workspace: workspace, fileSystem: InMemoryFileSystem()),
                                      terminals: ACPTerminalSession(workspace: workspace, random: random),
                                      clock: FakeClock(),
                                      random: random,
                                      recordBackgroundSessionEvents: recordBackground)
        }

        func modeUpdate(session: String, modeID: String) -> ACPIncoming {
            .notification(method: "session/update",
                          params: .object(["sessionId": .string(session),
                                           "update": .object(["sessionUpdate": .string("current_mode_update"),
                                                              "currentModeId": .string(modeID)])]))
        }

        func modelUpdate(session: String, modelID: String) -> ACPIncoming {
            .notification(method: "session/update",
                          params: .object(["sessionId": .string(session),
                                           "update": .object(["sessionUpdate": .string("current_model_update"),
                                                              "currentModelId": .string(modelID)])]))
        }

        func chunk(session: String, text: String, kind: String = "agent_message_chunk") -> ACPIncoming {
            .notification(method: "session/update",
                          params: .object(["sessionId": .string(session),
                                           "update": .object(["sessionUpdate": .string(kind),
                                                              "content": .object(["type": .string("text"),
                                                                                  "text": .string(text)])])]))
        }
    }
}
