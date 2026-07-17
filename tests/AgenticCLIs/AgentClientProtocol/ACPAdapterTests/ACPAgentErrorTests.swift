@testable import AgentClientProtocol
import AgentCore
import Testing

@Suite("ACP agent errors")
struct ACPAgentErrorTests {

    @Test("authenticationRequired maps to AgentError.authenticationRequired")
    func authenticationRequired() {
        let error = ACPAgentError.authenticationRequired(displayName: "Cursor").agentError
        if case .authenticationRequired(let id) = error {
            #expect(id == .other)
        } else {
            Issue.record("expected authenticationRequired")
        }
    }

    @Test("rpc and transport errors map to unsupportedOperation details")
    func unsupportedMappings() {
        #expect(ACPAgentError.rpc(code: -32_000, message: "nope").agentError ==
            .unsupportedOperation(detail: "acp:rpc:-32000:nope"))
        #expect(ACPAgentError.frameTooLarge(bytes: 9).detail.contains("frame-too-large"))
        #expect(ACPAgentError.pathOutsideWorkspace(path: "/etc").detail.contains("path-outside-workspace"))
        #expect(ACPAgentError.unknownServerRequest(method: "x").detail.contains("unknown-server-request"))
    }
}
