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
    ]
    public var transportDescriptor: AgentTransportDescriptor { .agentClientProtocol }
    public var historyNamespace: String { ref.id }

    private let ref: CustomAgentRef
    private let environment: any AgentEnvironment
    private let fileSystem: any FileSystem
    private let clock: any AgentClock
    private let random: any RandomSource
    private let state: ACPClientState

    public init(ref: CustomAgentRef,
                environment: any AgentEnvironment = SystemEnvironment(),
                fileSystem: any FileSystem = SystemFileSystem(),
                clock: any AgentClock = SystemClock(),
                random: any RandomSource = SystemRandomSource()) {
        self.ref = ref
        self.displayName = ref.displayName
        self.environment = environment
        self.fileSystem = fileSystem
        self.clock = clock
        self.random = random
        self.state = ACPClientState()
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
            fileAccess: fileAccess,
            terminals: terminals,
            clock: clock,
            random: random,
            recordBackgroundSessionEvents: inputs.recordBackgroundSessionEvents,
            updateSessionMetadata: inputs.updateSessionMetadata
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
        ACPInputEncoding.userPrompt(text, state: state)
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
            // Same stdio process, new ACP session id. The engine keeps the pool
            // slot; we do not respawn. Frames for the previous id stay on this
            // wire until the agent finishes them — `ACPEventDecoder` scopes by
            // `sessionId` (foreign stream cache / permission park) so they never
            // paint as the new chat.
            state.prepareNewSession()
            return ACPInputEncoding.sessionNew(state: state)
        case .runSlashCommand(let target, let args):
            return ACPInputEncoding.userPrompt(
                ([target.commandText] + args).joined(separator: " "),
                state: state
            )
        case .selectModel(let id):
            return ACPInputEncoding.setModel(modelID: id, state: state)
        default:
            return nil
        }
    }

    public func encodeA2UIAction(_ envelope: A2UIActionEnvelope) -> Data? {
        ACPInputEncoding.a2uiAction(envelope, state: state)
    }

    public func encodeA2UIClientError(_ envelope: A2UIClientErrorEnvelope) -> Data? {
        ACPInputEncoding.a2uiClientError(envelope, state: state)
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
        let optionID: String?
        switch decision {
        case .option(let id):
            optionID = id
        default:
            optionID = ACPPermissionMapping.optionID(for: decision, options: approval.optionIDs)
        }
        return .writePTY(ACPInputEncoding.permissionResponse(
            id: approval.requestID,
            optionID: optionID,
            cancelled: optionID == nil
        ))
    }

    public var slashCommandCatalog: [SlashCommand] { [] }

    public func enumerateProjectCommands(workspace: URL) async -> [SlashCommand] { [] }

    public func importSessionCatalog(
        workspace: URL,
        env _: ResolvedEnvironment,
        progress: @escaping @Sendable (Int, Int) async -> Void
    ) async throws -> [ImportedSession] {
        let importer = ACPSessionCatalogImporter(
            fileSystem: fileSystem,
            clock: clock,
            random: random
        )
        let sessions = try importer.sessions(workspace: workspace,
                                             customAgentID: ref.id)
        await progress(sessions.count, sessions.count)
        return sessions
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
