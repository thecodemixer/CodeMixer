import Foundation

import AgentClientProtocol
import AgentCore
import AgentProtocol

/// Shipping Cursor Agent adapter over ACP (`cursor-agent acp`).
///
/// Thin identity + launch + mode-mapping wrapper around `ACPAdapter`. Mode
/// switches use ACP `session/set_mode` for `agent` / `plan` / `ask`. `/debug`
/// is diagnostic-only and is not mapped to a session mode.
public final class CursorACPAdapter: AgentAdapter {
    public let id: AgentID = .cursorCLI
    public let displayName = "Cursor"
    public let iconSymbol = "cursorarrow.rays"
    public let capabilities: AgentCapabilities = [
        .permissionPrompts,
        .resumableSessions,
    ]
    public var transportDescriptor: AgentTransportDescriptor { .agentClientProtocol }

    private let environment: any AgentEnvironment
    private let fileSystem: any FileSystem
    private let locator: CursorBinaryLocator
    private let inner: ACPAdapter

    public init(environment: any AgentEnvironment = SystemEnvironment(),
                fileSystem: any FileSystem = SystemFileSystem(),
                clock: any AgentClock = SystemClock(),
                random: any RandomSource = SystemRandomSource()) {
        self.environment = environment
        self.fileSystem = fileSystem
        self.locator = CursorBinaryLocator(environment: environment, fileSystem: fileSystem)
        self.inner = ACPAdapter(
            ref: CustomAgentRef(
                id: "cursor",
                displayName: "Cursor",
                transport: .agentClientProtocol,
                executablePath: "/usr/bin/false",
                arguments: ["acp"]
            ),
            environment: environment,
            fileSystem: fileSystem,
            clock: clock,
            random: random
        )
    }

    public func locateBinary(env: ResolvedEnvironment) async throws -> URL {
        do {
            return try locator.locate(env: env)
        } catch let error as CursorBinaryLocator.LocateError {
            switch error {
            case .notFound(let checked):
                let locations = checked.prefix(4).joined(separator: ", ")
                throw AgentError.binaryNotFound(
                    agentID: .cursorCLI,
                    hint: "Install Cursor Agent CLI (`cursor-agent`). Checked: \(locations)"
                )
            }
        }
    }

    public func defaultEnvOverrides() -> [String: String] {
        ["NO_COLOR": "1"]
    }

    public func buildLaunchArgv(context: LaunchContext) -> [String] {
        ["cursor-agent", "acp"]
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

    public func encodeCommand(_ command: AgentCommand) -> Data? {
        switch command {
        case .setPermissionMode(let mode):
            guard let modeID = CursorModeCommand.modeID(forPermissionMode: mode) else {
                return nil
            }
            return inner.encodeSessionMode(modeID)
        case .runSlashCommand(let name, let args):
            if name == "/debug" || name == "debug" {
                // Diagnostic-only: not an ACP chat mode. Leave unsupported so
                // the engine surfaces an explicit error rather than pretending.
                return nil
            }
            if let mode = CursorModeCommand.chatMode(forSlash: name), args.isEmpty {
                return inner.encodeSessionMode(mode.modeID)
            }
            return inner.encodeCommand(command)
        case .toggleThinkMode(let enabled):
            // Composer "Agent" turns think/review off; map that to Cursor agent mode.
            return enabled ? nil : inner.encodeSessionMode(CursorModeCommand.agent.modeID)
        case .toggleReviewMode(let enabled):
            // Second half of the composer Agent selection — no-op write.
            return enabled ? nil : Data()
        default:
            return inner.encodeCommand(command)
        }
    }

    public func encodePermissionResponse(_ decision: PermissionDecision,
                                         for prompt: PermissionPrompt) -> PermissionResponseDelivery {
        inner.encodePermissionResponse(decision, for: prompt)
    }

    public var slashCommandCatalog: [SlashCommand] {
        CursorModeCommand.slashCatalog
    }

    public func availableAgentModes() -> [AgentModeOption] {
        CursorModeCommand.agentModes
    }

    public func enumerateProjectCommands(workspace: URL) async -> [SlashCommand] { [] }

    public func listResumableSessions(workspace: URL) async -> [SessionSummary] {
        let summaries = await inner.listResumableSessions(workspace: workspace)
        return summaries.map {
            SessionSummary(
                id: $0.id,
                agentID: .cursorCLI,
                workspace: $0.workspace,
                title: $0.title,
                lastActivity: $0.lastActivity,
                messageCount: $0.messageCount
            )
        }
    }

    public func resumeArgvAddition(sessionID: String) -> [String] { [] }
}
