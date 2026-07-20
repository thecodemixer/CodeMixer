@testable import AgentClientProtocol
import AgentCore
import AgentProtocol
import Foundation
import Testing

@Suite("ACP input encoding")
struct ACPInputEncodingTests {

    private let workspace = URL(fileURLWithPath: "/tmp/acp-ws")

    @Test("postInitialize emits initialized and session/new")
    func postInitialize() {
        let state = ACPClientState()
        _ = ACPInputEncoding.bootstrap(
            context: LaunchContext(workspace: workspace, permissionMode: .default),
            state: state,
            customAgentID: "x",
            displayName: "Agent"
        )
        let text = String(decoding: ACPInputEncoding.postInitialize(state: state), as: UTF8.self)
        #expect(text.contains("\"method\":\"initialized\""))
        #expect(text.contains("\"method\":\"session/new\""))
        #expect(text.contains("\"/tmp/acp-ws\""))
    }

    @Test("sessionOpen prefers session/load when resume id and loadSession are supported")
    func sessionLoadResume() {
        let state = ACPClientState()
        _ = ACPInputEncoding.bootstrap(
            context: LaunchContext(
                workspace: workspace,
                resumeSessionID: "resume-42",
                permissionMode: .default
            ),
            state: state,
            customAgentID: "x",
            displayName: "Agent"
        )
        state.setAgentCapabilities(.object(["loadSession": .bool(true)]))
        let text = String(decoding: ACPInputEncoding.sessionOpen(state: state), as: UTF8.self)
        #expect(text.contains("\"method\":\"session/load\""))
        #expect(text.contains("\"sessionId\":\"resume-42\""))
        #expect(!text.contains("session/new"))
    }

    @Test("sessionOpen uses session/resume when loadSession is unavailable")
    func sessionResumeFallback() {
        let state = ACPClientState()
        _ = ACPInputEncoding.bootstrap(
            context: LaunchContext(
                workspace: workspace,
                resumeSessionID: "resume-7",
                permissionMode: .default
            ),
            state: state,
            customAgentID: "x",
            displayName: "Agent"
        )
        state.setAgentCapabilities(.object([
            "sessionCapabilities": .object(["resume": .object([:])]),
        ]))
        let text = String(decoding: ACPInputEncoding.sessionOpen(state: state), as: UTF8.self)
        #expect(text.contains("\"method\":\"session/resume\""))
        #expect(text.contains("\"sessionId\":\"resume-7\""))
    }

    @Test("sessionOpen does not fall back to session/new when resume cannot be honored")
    func sessionOpenNoSilentNewOnUnsupportedResume() {
        let state = ACPClientState()
        _ = ACPInputEncoding.bootstrap(
            context: LaunchContext(
                workspace: workspace,
                resumeSessionID: "resume-missing",
                permissionMode: .default
            ),
            state: state,
            customAgentID: "x",
            displayName: "Agent"
        )
        state.setAgentCapabilities(.object([:]))
        #expect(ACPInputEncoding.sessionOpen(state: state).isEmpty)
        #expect(ACPInputEncoding.resumeUnsupportedAfterInitialize(state: state) == "resume-missing")
        let post = String(decoding: ACPInputEncoding.postInitialize(state: state), as: UTF8.self)
        #expect(post.contains("initialized"))
        #expect(!post.contains("session/new"))
        #expect(!post.contains("session/load"))
    }

    @Test("warm sessionLoad encodes session/load without re-bootstrap")
    func warmSessionLoad() {
        let state = ACPClientState()
        _ = ACPInputEncoding.bootstrap(
            context: LaunchContext(workspace: workspace, permissionMode: .default),
            state: state,
            customAgentID: "x",
            displayName: "Agent"
        )
        state.setAgentCapabilities(.object(["loadSession": .bool(true)]))
        state.setSessionID("old-session")
        let text = String(
            decoding: ACPInputEncoding.sessionLoad(sessionID: "warm-42", state: state),
            as: UTF8.self
        )
        #expect(text.contains("\"method\":\"session/load\""))
        #expect(text.contains("\"sessionId\":\"warm-42\""))
        #expect(state.sessionID() == nil)
        #expect(state.phase() == .awaitingSession)
    }

    @Test("userPrompt queues text until session id is available")
    func queuedPrompt() {
        let state = ACPClientState()
        _ = ACPInputEncoding.bootstrap(
            context: LaunchContext(workspace: workspace, permissionMode: .default),
            state: state,
            customAgentID: "x",
            displayName: "Agent"
        )
        #expect(ACPInputEncoding.userPrompt("hello", state: state).isEmpty)
        state.setSessionID("s1")
        let queued = String(decoding: ACPInputEncoding.queuedPrompts(state: state), as: UTF8.self)
        #expect(queued.contains("\"method\":\"session/prompt\""))
        #expect(queued.contains("\"sessionId\":\"s1\""))
        #expect(queued.contains("hello"))
    }

    @Test("userPrompt encodes attachment lines as separate content blocks")
    func promptAttachmentBlocks() {
        let state = ACPClientState()
        _ = ACPInputEncoding.bootstrap(
            context: LaunchContext(workspace: workspace, permissionMode: .default),
            state: state,
            customAgentID: "x",
            displayName: "Agent"
        )
        state.setSessionID("s1")
        let text = String(
            decoding: ACPInputEncoding.userPrompt("fix this\n@/tmp/file.swift", state: state),
            as: UTF8.self
        )
        #expect(text.contains("fix this"))
        #expect(text.contains("/tmp/file.swift"))
    }

    @Test("cancel emits session/cancel when session exists")
    func cancelWithSession() {
        let state = ACPClientState()
        _ = ACPInputEncoding.bootstrap(
            context: LaunchContext(workspace: workspace, permissionMode: .default),
            state: state,
            customAgentID: "x",
            displayName: "Agent"
        )
        state.setSessionID("s1")
        let text = String(decoding: ACPInputEncoding.cancel(state: state), as: UTF8.self)
        #expect(text.contains("\"method\":\"session/cancel\""))
        #expect(text.contains("\"sessionId\":\"s1\""))
    }

    @Test("listSessions is nil without list capability")
    func listSessionsGated() {
        let state = ACPClientState()
        _ = ACPInputEncoding.bootstrap(
            context: LaunchContext(workspace: workspace, permissionMode: .default),
            state: state,
            customAgentID: "x",
            displayName: "Agent"
        )
        #expect(ACPInputEncoding.listSessions(state: state) == nil)
        state.setAgentCapabilities(.object([
            "sessionCapabilities": .object(["list": .object([:])]),
        ]))
        let text = String(decoding: ACPInputEncoding.listSessions(state: state)!, as: UTF8.self)
        #expect(text.contains("\"method\":\"session/list\""))
    }

    @Test("permissionResponse encodes selected and cancelled outcomes")
    func permissionResponse() {
        let selected = String(
            decoding: ACPInputEncoding.permissionResponse(
                id: .number(9),
                optionID: "allow_once",
                cancelled: false
            ),
            as: UTF8.self
        )
        #expect(selected.contains("\"outcome\":\"selected\""))
        #expect(selected.contains("\"optionId\":\"allow_once\""))

        let cancelled = String(
            decoding: ACPInputEncoding.permissionResponse(
                id: .number(9),
                optionID: nil,
                cancelled: true
            ),
            as: UTF8.self
        )
        #expect(cancelled.contains("\"outcome\":\"cancelled\""))
    }
}
