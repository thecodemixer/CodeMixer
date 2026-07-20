import Foundation

import AgentCore
import AgentProtocol

/// Deterministic in-process specification of the ACP adapter contract.
public final class ACPTwin: AgentAdapter {
    public struct Configuration: Sendable {
        public var sessionID: String
        public var reply: String
        public var requireAuth: Bool

        public init(sessionID: String = "acp-twin-session",
                    reply: String = "Hello from ACP twin.",
                    requireAuth: Bool = false) {
            self.sessionID = sessionID
            self.reply = reply
            self.requireAuth = requireAuth
        }
    }

    public let id: AgentID = .other
    public let displayName = "ACP Twin"
    public let iconSymbol = "terminal"
    public let capabilities: AgentCapabilities = [
        .permissionPrompts,
        .resumableSessions,
        .sessionHandshakeGate,
    ]
    public var transportDescriptor: AgentTransportDescriptor { .agentClientProtocol }

    public let configuration: Configuration
    private let state = ACPClientState()
    private let clock: any AgentClock
    private let random: any RandomSource

    public init(configuration: Configuration = Configuration(),
                clock: any AgentClock = SystemClock(),
                random: any RandomSource = SystemRandomSource()) {
        self.configuration = configuration
        self.clock = clock
        self.random = random
    }

    public func locateBinary(env: ResolvedEnvironment) async throws -> URL {
        URL(fileURLWithPath: "/usr/bin/true")
    }

    public func defaultEnvOverrides() -> [String: String] { [:] }

    public func buildLaunchArgv(context: LaunchContext) -> [String] { ["true"] }

    public func authStatus(env: ResolvedEnvironment) async -> AuthStatus {
        configuration.requireAuth ? .unauthenticated : .authenticated(account: "twin")
    }

    public func makeEventStream(inputs: AgentInputs) -> AsyncStream<AgentEvent> {
        let configuration = self.configuration
        let random = self.random
        return AsyncStream(
            bufferingPolicy: .bufferingNewest(StreamBufferDefaults.adapterEvents)
        ) { continuation in
            if configuration.requireAuth {
                continuation.yield(.error(.authenticationRequired(agentID: .other)))
                continuation.finish()
                return
            }
            continuation.yield(.sessionStarted(
                sessionID: configuration.sessionID,
                model: nil,
                cwd: inputs.workspace
            ))
            let messageID = random.uuid().uuidString
            continuation.yield(.assistantText(
                id: messageID,
                blockID: messageID,
                text: configuration.reply,
                isFinal: true
            ))
            continuation.finish()
        }
    }

    public func encodeUserPrompt(_ text: String) -> Data {
        state.setSessionID(configuration.sessionID)
        return ACPInputEncoding.userPrompt(text, state: state)
    }

    public func cancelSequence() -> Data {
        ACPInputEncoding.cancel(state: state)
    }

    public func sessionBootstrapBytes(context: LaunchContext) -> Data {
        let bytes = ACPInputEncoding.bootstrap(
            context: context,
            state: state,
            customAgentID: "twin",
            displayName: displayName
        )
        if !configuration.requireAuth {
            state.setSessionID(configuration.sessionID)
        }
        return bytes
    }

    public func encodeCommand(_ command: AgentCommand) -> Data? {
        switch command {
        case .newSession:
            state.prepareNewSession()
            state.setSessionID(configuration.sessionID)
            return ACPInputEncoding.sessionNew(state: state)
        default:
            return nil
        }
    }

    public func encodePermissionResponse(_ decision: PermissionDecision,
                                         for prompt: PermissionPrompt) -> PermissionResponseDelivery {
        .writePTY(Data())
    }

    public var slashCommandCatalog: [SlashCommand] { [] }

    public func enumerateProjectCommands(workspace: URL) async -> [SlashCommand] { [] }

    public func listResumableSessions(workspace: URL) async -> [SessionSummary] {
        [
            SessionSummary(
                id: configuration.sessionID,
                agentID: .other,
                workspace: workspace,
                title: "ACP Twin Session",
                lastActivity: clock.now(),
                messageCount: 1
            ),
        ]
    }

    public func resumeArgvAddition(sessionID: String) -> [String] { [] }
}
