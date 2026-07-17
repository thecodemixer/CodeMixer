import Foundation

import AgentCore
import AgentProtocol

/// Deterministic in-process specification of the Codex adapter contract.
///
/// The twin emits Codemixer events directly while reusing the production
/// protocol encoders, catalogs, and policy mapping. It does not ship or spawn
/// a fake Codex executable.
public final class CodexTwin: AgentAdapter {
    public struct Configuration: Sendable {
        public let threadID: String
        public let model: String
        public let reply: String

        public init(threadID: String = "codex-twin-thread",
                    model: String = "gpt-5.4",
                    reply: String = "Hello from the Codex twin.") {
            self.threadID = threadID
            self.model = model
            self.reply = reply
        }
    }

    public let id: AgentID = .codex
    public let displayName = "Codex (digital twin)"
    public let iconSymbol = "terminal"
    public let capabilities: AgentCapabilities = [
        .permissionPrompts,
        .resumableSessions,
    ]
    public var transportDescriptor: AgentTransportDescriptor { .stdioJSONRPC }

    public let configuration: Configuration
    private let state = CodexSessionState()
    private let environment: any AgentEnvironment
    private let fileSystem: any FileSystem
    private let clock: any AgentClock
    private let random: any RandomSource

    public init(configuration: Configuration = Configuration(),
                environment: any AgentEnvironment = SystemEnvironment(),
                fileSystem: any FileSystem = SystemFileSystem(),
                clock: any AgentClock = SystemClock(),
                random: any RandomSource = SystemRandomSource()) {
        self.configuration = configuration
        self.environment = environment
        self.fileSystem = fileSystem
        self.clock = clock
        self.random = random
    }

    public func locateBinary(env: ResolvedEnvironment) async throws -> URL {
        URL(fileURLWithPath: "/usr/bin/true")
    }

    public func defaultEnvOverrides() -> [String: String] { [:] }

    public func buildLaunchArgv(context: LaunchContext) -> [String] {
        ["true"]
    }

    public func authStatus(env: ResolvedEnvironment) async -> AuthStatus {
        .authenticated(account: "codex-twin@codemixer.local")
    }

    public func makeEventStream(inputs: AgentInputs) -> AsyncStream<AgentEvent> {
        let configuration = self.configuration
        let random = self.random
        return AsyncStream(
            bufferingPolicy: .bufferingNewest(StreamBufferDefaults.adapterEvents)
        ) { continuation in
            continuation.yield(.sessionStarted(
                sessionID: configuration.threadID,
                model: configuration.model,
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
        ensureThread()
        return CodexInputEncoding.userPrompt(text, state: state)
    }

    public func cancelSequence() -> Data {
        CodexInputEncoding.interrupt(state: state)
    }

    public func sessionBootstrapBytes(context: LaunchContext) -> Data {
        let bytes = CodexInputEncoding.bootstrap(
            context: context,
            state: state,
            clientVersion: "twin"
        )
        state.setThreadID(configuration.threadID)
        return bytes
    }

    public func encodeCommand(_ command: AgentCommand) -> Data? {
        ensureThread()
        switch command {
        case .compact:
            return CodexInputEncoding.compact(state: state)
        case .selectModel(let id):
            if let option = availableModels().first(where: { $0.code == id }) {
                state.selectModel(option)
            } else {
                state.selectModel(code: id, thinkingEffort: nil)
            }
            return Data()
        case .toggleReviewMode(let enabled):
            return enabled ? CodexInputEncoding.review(state: state) : nil
        case .runSlashCommand(let name, let args):
            return CodexInputEncoding.userPrompt(
                ([name] + args).joined(separator: " "),
                state: state
            )
        case .runCustomCommand(let path, let args):
            return CodexInputEncoding.userPrompt(
                ([path] + args).joined(separator: " "),
                state: state
            )
        default:
            return nil
        }
    }

    public func encodePermissionResponse(_ decision: PermissionDecision,
                                         for prompt: PermissionPrompt) -> PermissionResponseDelivery {
        guard let approval = state.takeApproval(
            id: prompt.id,
            remember: decision == .allowAlways
        ) else {
            return .writePTY(Data())
        }
        return .writePTY(CodexInputEncoding.permissionResponse(
            id: approval.requestID,
            allow: decision != .deny
        ))
    }

    public var slashCommandCatalog: [SlashCommand] {
        CodexCommandCatalog.builtIn
    }

    public func enumerateProjectCommands(workspace: URL) async -> [SlashCommand] {
        CodexCommandCatalog.projectCommands(
            workspace: workspace,
            codexDirectory: environment.homeDirectory
                .appendingPathComponent(".codex", isDirectory: true),
            fileSystem: fileSystem
        )
    }

    public func listResumableSessions(workspace: URL) async -> [SessionSummary] {
        [
            SessionSummary(
                id: configuration.threadID,
                agentID: .codex,
                workspace: workspace,
                title: "Codex twin session",
                lastActivity: clock.now(),
                messageCount: 1
            ),
        ]
    }

    public func resumeArgvAddition(sessionID: String) -> [String] { [] }

    public func availableModels() -> [AgentModelOption] {
        []
    }

    public func truncateTranscript(afterUserTurnID turnID: String,
                                   sessionID: String,
                                   workspace: URL) async -> Bool {
        false
    }

    private func ensureThread() {
        if state.threadID() == nil {
            state.setThreadID(configuration.threadID)
        }
    }
}
