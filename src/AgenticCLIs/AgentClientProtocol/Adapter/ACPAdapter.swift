import Foundation

import AgentCore
import AgentProtocol

/// Production adapter for user-configured ACP agent servers over stdio JSON-RPC.
public final class ACPAdapter: AgentAdapter {
    public let id: AgentID = .other
    public let displayName: String
    public let iconSymbol = "terminal"
    public let capabilities: AgentCapabilities = [
        .permissionPrompts,
        .resumableSessions,
        .sessionHandshakeGate,
    ]
    public var transportDescriptor: AgentTransportDescriptor { .agentClientProtocol }

    private let ref: CustomAgentRef
    private let environment: any AgentEnvironment
    private let fileSystem: any FileSystem
    private let clock: any AgentClock
    private let random: any RandomSource
    private let state: ACPClientState
    private let sessionIndex: any ACPSessionIndexing

    public init(ref: CustomAgentRef,
                environment: any AgentEnvironment = SystemEnvironment(),
                fileSystem: any FileSystem = SystemFileSystem(),
                clock: any AgentClock = SystemClock(),
                random: any RandomSource = SystemRandomSource(),
                sessionIndex: (any ACPSessionIndexing)? = nil) {
        self.ref = ref
        self.displayName = ref.displayName
        self.environment = environment
        self.fileSystem = fileSystem
        self.clock = clock
        self.random = random
        self.state = ACPClientState()
        self.sessionIndex = sessionIndex ?? ACPSessionIndex(
            environment: environment,
            fileSystem: fileSystem,
            clock: clock
        )
    }

    public func locateBinary(env: ResolvedEnvironment) async throws -> URL {
        let url = URL(fileURLWithPath: ref.executablePath)
        guard fileSystem.fileExists(at: url) else {
            throw AgentError.binaryNotFound(
                agentID: .other,
                hint: "Install or configure \(ref.displayName) at \(ref.executablePath)."
            )
        }
        return url
    }

    public func defaultEnvOverrides() -> [String: String] {
        ["NO_COLOR": "1"]
    }

    public func buildLaunchArgv(context: LaunchContext) -> [String] {
        let exeName = URL(fileURLWithPath: ref.executablePath).lastPathComponent
        return [exeName] + ref.arguments
    }

    public func authStatus(env: ResolvedEnvironment) async -> AuthStatus {
        .unknown
    }

    public func makeEventStream(inputs: AgentInputs) -> AsyncStream<AgentEvent> {
        let fileAccess = ACPFileAccess(workspace: inputs.workspace, fileSystem: fileSystem)
        let terminals = ACPTerminalSession(workspace: inputs.workspace, random: random)
        let decoder = ACPEventDecoder(
            state: state,
            sessionIndex: sessionIndex,
            fileAccess: fileAccess,
            terminals: terminals,
            clock: clock,
            random: random
        )
        return AsyncStream(
            bufferingPolicy: .bufferingNewest(StreamBufferDefaults.adapterEvents)
        ) { continuation in
            let task = Task {
                var framing = ACPFraming()
                for await bytes in inputs.outputBytes {
                    do {
                        let frames = try framing.append(bytes)
                        for frame in frames {
                            let incoming = try ACPRPCCodec.decode(frame)
                            let batch = await decoder.decode(incoming)
                            for event in batch.events {
                                continuation.yield(event)
                            }
                            for reply in batch.replies {
                                do {
                                    try await inputs.writeBytes(reply)
                                } catch {
                                    continuation.yield(.error(ACPAgentError
                                        .malformedMessage(detail: "reply-write:\(error)")
                                        .agentError))
                                }
                            }
                        }
                    } catch let error as ACPAgentError {
                        continuation.yield(.error(error.agentError))
                    } catch {
                        continuation.yield(.error(ACPAgentError
                            .malformedFrame(detail: String(describing: error))
                            .agentError))
                    }
                }
                continuation.finish()
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }

    public func encodeUserPrompt(_ text: String) -> Data {
        let data = ACPInputEncoding.userPrompt(text, state: state)
        if let sessionID = state.sessionID(),
           let context = state.currentContext() {
            Task {
                await sessionIndex.recordTurn(
                    sessionID: sessionID,
                    customAgentID: context.customAgentID,
                    title: text
                )
                await sessionIndex.appendConversationTurn(
                    sessionID: sessionID,
                    customAgentID: context.customAgentID,
                    role: "user",
                    text: text
                )
            }
        }
        return data
    }

    public func cancelSequence() -> Data {
        ACPInputEncoding.cancel(state: state)
    }

    public func sessionBootstrapBytes(context: LaunchContext) -> Data {
        ACPInputEncoding.bootstrap(
            context: context,
            state: state,
            customAgentID: ref.id,
            displayName: ref.displayName
        )
    }

    public func encodeCommand(_ command: AgentCommand) -> Data? {
        switch command {
        case .newSession:
            state.prepareNewSession()
            return ACPInputEncoding.sessionNew(state: state)
        case .runSlashCommand(let name, let args):
            return ACPInputEncoding.userPrompt(
                ([name] + args).joined(separator: " "),
                state: state
            )
        case .runCustomCommand(let path, let args):
            return ACPInputEncoding.userPrompt(
                ([path] + args).joined(separator: " "),
                state: state
            )
        case .selectModel(let id):
            return ACPInputEncoding.setModel(modelID: id, state: state)
        default:
            return nil
        }
    }

    public func encodeResumeSession(sessionID: String) -> Data? {
        let data = ACPInputEncoding.sessionLoad(sessionID: sessionID, state: state)
        return data.isEmpty ? nil : data
    }

    /// Encodes ACP `session/set_mode` for agents that advertise `availableModes`.
    public func encodeSessionMode(_ modeID: String) -> Data {
        ACPInputEncoding.setMode(modeID: modeID, state: state)
    }

    public func encodePermissionResponse(_ decision: PermissionDecision,
                                         for prompt: PermissionPrompt) -> PermissionResponseDelivery {
        guard let approval = state.takeApproval(id: prompt.id) else {
            return .writePTY(Data())
        }
        if decision == .allowAlways {
            let signature = "\(prompt.toolName)|\(prompt.summary)"
            state.rememberAutoApproval(signature: signature)
        }
        let optionID = ACPPermissionMapping.optionID(
            for: decision,
            options: approval.optionIDs
        )
        return .writePTY(ACPInputEncoding.permissionResponse(
            id: approval.requestID,
            optionID: optionID,
            cancelled: optionID == nil
        ))
    }

    public var slashCommandCatalog: [SlashCommand] { [] }

    public func enumerateProjectCommands(workspace: URL) async -> [SlashCommand] { [] }

    public func listResumableSessions(workspace: URL) async -> [SessionSummary] {
        await sessionIndex.summaries(workspace: workspace, customAgentID: ref.id)
    }

    public func availableModels() -> [AgentModelOption] {
        state.availableModels()
    }

    /// Session modes advertised on the last `session/new` / `session/load`.
    public func sessionAvailableModes() -> [ACPSessionMode] {
        state.availableModes()
    }

    public func sessionCurrentModeID() -> String? {
        state.currentModeID()
    }

    public func resumeArgvAddition(sessionID: String) -> [String] { [] }
}

/// Registers ACP adapters for custom projects that select Agent Client Protocol.
public struct ACPCustomAgentAdapterFactory: CustomAgentAdapterFactory {
    public init() {}

    public func makeAdapter(for ref: CustomAgentRef) -> (any AgentAdapter)? {
        guard ref.transport.kind == .agentClientProtocol else { return nil }
        return ACPAdapter(ref: ref)
    }
}
