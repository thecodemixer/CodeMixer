import Foundation
import Testing
@testable import AgentClientProtocol
import AgentCore
import AgentTestSupport

/// Documents the warm-resume path used by Custom ACP (factory-cached adapter
/// process): `prepareLoadSession` + `session/load` flips the foreground
/// `sessionId`, and streaming chunks for other sessions are dropped.
@Suite("Custom ACP warm session switch")
struct WarmSessionSwitchTests {

    @Test("rapid A to B to A load keeps streaming scoped to foreground sessionId")
    func rapidWarmResumeScoping() async {
        let workspace = TestPaths.underTemporary("custom-acp-warm-ws")
        let fileSystem = InMemoryFileSystem()
        let clock = FakeClock()
        let random = FakeRandomSource()
        let state = ACPClientState()
        let sessionIndex = ACPSessionIndex(
            environment: FakeEnvironment(),
            fileSystem: fileSystem,
            clock: clock
        )
        let decoder = ACPEventDecoder(
            state: state,
            sessionIndex: sessionIndex,
            fileAccess: ACPFileAccess(workspace: workspace, fileSystem: fileSystem),
            terminals: ACPTerminalSession(workspace: workspace, random: random),
            clock: clock,
            random: random
        )
        _ = ACPInputEncoding.bootstrap(
            context: LaunchContext(
                workspace: workspace,
                resumeSessionID: nil,
                permissionMode: .default
            ),
            state: state,
            customAgentID: "migration-assistant",
            displayName: "Migration Assistant"
        )

        _ = await decoder.decode(.response(
            id: .number(1),
            result: .object([
                "protocolVersion": .number(1),
                "agentCapabilities": .object(["loadSession": .bool(true)]),
                "authMethods": .array([]),
            ]),
            error: nil
        ))
        _ = await decoder.decode(.response(
            id: .number(2),
            result: .object(["sessionId": .string("sess-A")]),
            error: nil
        ))

        state.prepareLoadSession(sessionID: "sess-B")
        let loadB = state.nextRequestID(for: .sessionLoad)
        state.setPhase(.awaitingSession)
        _ = await decoder.decode(.response(
            id: loadB,
            result: .object(["sessionId": .string("sess-B")]),
            error: nil
        ))

        let foreignA = await decoder.decode(.notification(
            method: "session/update",
            params: .object([
                "sessionId": .string("sess-A"),
                "update": .object([
                    "sessionUpdate": .string("agent_message_chunk"),
                    "content": .object(["text": .string("leak-A")]),
                ]),
            ])
        ))
        #expect(foreignA.events.isEmpty)
        #expect(state.sessionID() == "sess-B")

        state.prepareLoadSession(sessionID: "sess-A")
        let loadA = state.nextRequestID(for: .sessionLoad)
        state.setPhase(.awaitingSession)
        _ = await decoder.decode(.response(
            id: loadA,
            result: .object(["sessionId": .string("sess-A")]),
            error: nil
        ))

        let foreignB = await decoder.decode(.notification(
            method: "session/update",
            params: .object([
                "sessionId": .string("sess-B"),
                "update": .object([
                    "sessionUpdate": .string("agent_message_chunk"),
                    "content": .object(["text": .string("leak-B")]),
                ]),
            ])
        ))
        #expect(foreignB.events.isEmpty)
        #expect(state.sessionID() == "sess-A")

        let promptID = state.nextRequestID(for: .sessionPrompt)
        _ = await decoder.decode(.notification(
            method: "session/update",
            params: .object([
                "sessionId": .string("sess-A"),
                "update": .object([
                    "sessionUpdate": .string("agent_message_chunk"),
                    "content": .object(["text": .string("warm-A")]),
                ]),
            ])
        ))
        let done = await decoder.decode(.response(
            id: promptID,
            result: .object(["stopReason": .string("end_turn")]),
            error: nil
        ))
        #expect(done.events.contains {
            if case .assistantText(_, _, let text, true) = $0 { return text == "warm-A" }
            return false
        })
    }
}
