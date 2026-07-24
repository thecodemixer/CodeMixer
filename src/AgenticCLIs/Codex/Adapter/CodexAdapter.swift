import Foundation

import AgentCore
import AgentProtocol

/// Production adapter for `codex app-server --stdio`.
///
/// The adapter owns JSONL framing, JSON-RPC session state, permission routing,
/// and Codemixer's lightweight resumable-thread index. Codex remains the owner
/// of conversation history and authentication credentials.
public final class CodexAdapter: AgentAdapter {
    public let id: AgentID = .codex
    public let displayName = "Codex"
    public let iconSymbol = "terminal"
    public let capabilities: AgentCapabilities = [
        .permissionPrompts,
        .resumableSessions,
    ]
    public var transportDescriptor: AgentTransportDescriptor { .stdioJSONRPC }

    private let environment: any AgentEnvironment
    private let fileSystem: any FileSystem
    private let clock: any AgentClock
    private let random: any RandomSource
    private let processRunner: ProcessRunner
    private let binaryLocator: CodexBinaryLocator
    private let state: CodexSessionState
    private let threadIndex: CodexThreadIndex
    private let modelCache: AgentModelCatalogCache

    private static let clientVersion = "0.1.0"

    public init(environment: any AgentEnvironment = SystemEnvironment(),
                fileSystem: any FileSystem = SystemFileSystem(),
                clock: any AgentClock = SystemClock(),
                random: any RandomSource = SystemRandomSource(),
                processRunner: ProcessRunner = ProcessRunner(),
                initialModels: [AgentModelOption] = []) {
        self.environment = environment
        self.fileSystem = fileSystem
        self.clock = clock
        self.random = random
        self.processRunner = processRunner
        self.binaryLocator = CodexBinaryLocator(
            environment: environment,
            fileSystem: fileSystem
        )
        self.state = CodexSessionState()
        self.threadIndex = CodexThreadIndex(
            environment: environment,
            fileSystem: fileSystem,
            clock: clock
        )
        self.modelCache = AgentModelCatalogCache(models: initialModels)
    }

    public func locateBinary(env: ResolvedEnvironment) async throws -> URL {
        do {
            return try binaryLocator.locate(env: env)
        } catch let error as CodexBinaryLocator.LocateError {
            switch error {
            case .notFound(let checked):
                let locations = checked.prefix(4).joined(separator: ", ")
                throw AgentError.binaryNotFound(
                    agentID: .codex,
                    hint: "Install Codex CLI with `npm install -g @openai/codex`. Checked: \(locations)"
                )
            }
        }
    }

    public func defaultEnvOverrides() -> [String: String] {
        ["NO_COLOR": "1"]
    }

    public func buildLaunchArgv(context: LaunchContext) -> [String] {
        ["codex", "app-server", "--stdio"]
    }

    public func authStatus(env: ResolvedEnvironment) async -> AuthStatus {
        let binary: URL
        do {
            binary = try binaryLocator.locate(env: env)
        } catch {
            await recordAuthProbeHint("Codex binary unavailable. Install `@openai/codex`.")
            return .unknown
        }

        do {
            let result = try await processRunner.run(
                executable: binary,
                arguments: ["login", "status"],
                env: env.variables
            )
            let status = authStatus(from: result.stdout + result.stderr)
            if status == .unknown {
                await recordAuthProbeHint(
                    "Run `codex login status` in Terminal; the CLI returned an unrecognized response."
                )
            }
            return status
        } catch let ProcessRunner.ProcessError.nonZeroExit(_, stderr) {
            if stderr.localizedCaseInsensitiveContains("not logged in") {
                return .unauthenticated
            }
            await recordAuthProbeHint("Run `codex login status` in Terminal. \(stderr)")
            return .unknown
        } catch {
            await recordAuthProbeHint("Run `codex login status` in Terminal. \(error)")
            return .unknown
        }
    }

    public func makeEventStream(inputs: AgentInputs) -> AsyncStream<AgentEvent> {
        let decoder = CodexEventDecoder(
            state: state,
            threadIndex: threadIndex,
            workspace: inputs.workspace,
            clock: clock,
            random: random
        )
        return AsyncStream(
            bufferingPolicy: .bufferingNewest(StreamBufferDefaults.adapterEvents)
        ) { continuation in
            let task = Task {
                var framing = CodexAppServerFraming()
                for await bytes in inputs.outputBytes {
                    do {
                        let frames = try framing.append(bytes)
                        for frame in frames {
                            let incoming = try CodexRPCCodec.decode(frame)
                            let batch = await decoder.decode(incoming)
                            for event in batch.events {
                                continuation.yield(event)
                            }
                            for reply in batch.replies {
                                do {
                                    try await inputs.writeBytes(reply)
                                } catch {
                                    continuation.yield(.error(CodexAgentError
                                        .malformedMessage(detail: "reply-write:\(error)")
                                        .agentError))
                                }
                            }
                        }
                    } catch let error as CodexAgentError {
                        continuation.yield(.error(error.agentError))
                    } catch {
                        continuation.yield(.error(CodexAgentError
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
        CodexInputEncoding.userPrompt(text, state: state)
    }

    public func cancelSequence() -> Data {
        CodexInputEncoding.interrupt(state: state)
    }

    public func sessionBootstrapBytes(context: LaunchContext) -> Data {
        CodexInputEncoding.bootstrap(
            context: context,
            state: state,
            clientVersion: Self.clientVersion
        )
    }

    public func encodeCommand(_ command: AgentCommand) -> Data? {
        switch command {
        case .newSession:
            guard let context = state.currentContext() else { return nil }
            state.prepareNewThread()
            return CodexInputEncoding.startThread(
                context: LaunchContext(
                    workspace: context.workspace,
                    permissionMode: context.permissionMode
                ),
                state: state
            )
        case .compact:
            return CodexInputEncoding.compact(state: state)
        case .setAgentMode(let id):
            return id == AgentModeCommandID.review ? CodexInputEncoding.review(state: state) : nil
        case .runSlashCommand(let target, let args):
            return CodexInputEncoding.userPrompt(
                ([target.commandText] + args).joined(separator: " "),
                state: state
            )
        case .selectModel(let id):
            if let option = availableModels().first(where: { $0.code == id }) {
                state.selectModel(option)
            } else {
                state.selectModel(code: id, thinkingEffort: nil)
            }
            return Data()
        case .setPermissionMode:
            return nil
        default:
            return nil
        }
    }

    public func encodePermissionResponse(_ decision: PermissionDecision,
                                         for prompt: PermissionPrompt) -> PermissionResponseDelivery {
        let remember = decision == .allowAlways
        guard let approval = state.takeApproval(id: prompt.id, remember: remember) else {
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
        await threadIndex.summaries(workspace: workspace)
    }

    public func resumeArgvAddition(sessionID: String) -> [String] {
        []
    }

    public func availableModels() -> [AgentModelOption] {
        let cached = modelCache.snapshot()
        if !cached.isEmpty { return cached }
        let loaded = CodexModelCatalog.load(
            codexHome: environment.homeDirectory
                .appendingPathComponent(".codex", isDirectory: true),
            fileSystem: fileSystem
        )
        if !loaded.isEmpty {
            modelCache.replace(with: loaded)
        }
        return loaded
    }

    public func refreshModelCatalog() async throws -> [AgentModelOption] {
        let loaded = CodexModelCatalog.load(
            codexHome: environment.homeDirectory
                .appendingPathComponent(".codex", isDirectory: true),
            fileSystem: fileSystem
        )
        if !loaded.isEmpty {
            modelCache.replace(with: loaded)
        }
        return loaded
    }

    public func seedModelCatalog(_ models: [AgentModelOption]) {
        modelCache.replace(with: models)
    }

    public func availableAgentModes() -> [AgentModeOption] {
        [
            AgentModeOption(
                id: "agent",
                label: "Agent",
                selectCommands: []
            ),
            AgentModeOption(
                id: "review",
                label: "Review",
                selectCommands: [.setAgentMode(id: AgentModeCommandID.review)]
            ),
        ]
    }

    public func truncateTranscript(afterUserTurnID turnID: String,
                                   sessionID: String,
                                   workspace: URL) async -> Bool {
        await threadIndex.supersede(threadID: sessionID)
        return false
    }

    private func authStatus(from data: Data) -> AuthStatus {
        let text = String(decoding: data, as: UTF8.self)
        if text.localizedCaseInsensitiveContains("not logged in") {
            return .unauthenticated
        }
        if text.localizedCaseInsensitiveContains("logged in") {
            let account = text.split(separator: "\n")
                .first { $0.contains("@") }
                .map { String($0).trimmingCharacters(in: .whitespaces) }
            return .authenticated(account: account)
        }
        return .unknown
    }

    private func recordAuthProbeHint(_ hint: String) async {
        await SilentDiagnostics.shared.record(
            kind: .other,
            owner: "CodexAdapter",
            summary: "Codex auth status unknown",
            details: hint
        )
    }
}

