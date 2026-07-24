import Foundation

import AgentClientProtocol
import AgentCore
import AgentProtocol

/// Default forwarding for the `AgentAdapter` requirements that both
/// ACP-backed adapters (`CursorACPAdapter`, `CustomACPAdapter`) delegate to
/// their wrapped `ACPAdapter` byte-for-byte. Conformers still implement
/// identity, launch, and mode-mapping (`encodeCommand`, `availableAgentModes`,
/// `availableModels`, `listResumableSessions`, …) themselves — those differ
/// per vendor and are not pure forwarding.
protocol ACPBackedAdapter: AgentAdapter {
    var inner: ACPAdapter { get }
}

extension ACPBackedAdapter {
    public func defaultEnvOverrides() -> [String: String] {
        ["NO_COLOR": "1"]
    }

    public func authStatus(env: ResolvedEnvironment) async -> AuthStatus {
        .unknown
    }

    public func makeEventStream(inputs: AgentInputs) -> AsyncStream<AgentEvent> {
        inner.makeEventStream(inputs: inputs)
    }

    public func encodeUserPrompt(_ text: String) -> Data {
        inner.encodeUserPrompt(text)
    }

    public func cancelSequence() -> Data {
        inner.cancelSequence()
    }

    public func sessionBootstrapBytes(context: LaunchContext) -> Data {
        inner.sessionBootstrapBytes(context: context)
    }

    public func encodeResumeSession(sessionID: String) -> Data? {
        inner.encodeResumeSession(sessionID: sessionID)
    }

    public func encodePermissionResponse(_ decision: PermissionDecision,
                                         for prompt: PermissionPrompt) -> PermissionResponseDelivery {
        inner.encodePermissionResponse(decision, for: prompt)
    }

    public func enumerateProjectCommands(workspace: URL) async -> [SlashCommand] { [] }

    public func resumeArgvAddition(sessionID: String) -> [String] { [] }
}
