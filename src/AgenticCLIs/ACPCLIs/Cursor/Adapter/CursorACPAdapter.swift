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
    private let processRunner: ProcessRunner
    private let modelCache: CursorModelCache
    private let inner: ACPAdapter

    public init(environment: any AgentEnvironment = SystemEnvironment(),
                fileSystem: any FileSystem = SystemFileSystem(),
                clock: any AgentClock = SystemClock(),
                random: any RandomSource = SystemRandomSource(),
                processRunner: ProcessRunner = ProcessRunner(),
                initialModels: [AgentModelOption] = []) {
        self.environment = environment
        self.fileSystem = fileSystem
        self.locator = CursorBinaryLocator(environment: environment, fileSystem: fileSystem)
        self.processRunner = processRunner
        self.modelCache = CursorModelCache(models: initialModels)
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
        let binary = try resolveBinary(env: env)
        // Do not block session start on `cursor-agent models` (often many
        // seconds). A late catalog fill must not delay / race project switches.
        Task { [processRunner, modelCache] in
            let models = await Self.probeModels(
                executable: binary,
                env: discoveryEnvironment(from: env),
                processRunner: processRunner
            )
            if !models.isEmpty {
                modelCache.replace(with: models)
            }
        }
        return binary
    }

    public func refreshModelCatalog() async throws -> [AgentModelOption] {
        let env = await ShellEnvironmentResolver(
            environment: environment,
            processRunner: processRunner
        ).resolve()
        let binary = try resolveBinary(env: env)
        let models = await Self.probeModels(
            executable: binary,
            env: discoveryEnvironment(from: env),
            processRunner: processRunner
        )
        if !models.isEmpty {
            modelCache.replace(with: models)
        }
        return modelCache.snapshot()
    }

    public func seedModelCatalog(_ models: [AgentModelOption]) {
        modelCache.replace(with: models)
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
        case .selectModel(let id):
            return inner.encodeCommand(.selectModel(id: id))
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

    public func availableModels() -> [AgentModelOption] {
        let live = inner.availableModels()
        return live.isEmpty ? modelCache.snapshot() : live
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

    private func resolveBinary(env: ResolvedEnvironment) throws -> URL {
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

    private func discoveryEnvironment(from env: ResolvedEnvironment) -> [String: String] {
        env.withOverrides(defaultEnvOverrides())
    }

    private static func probeModels(executable: URL,
                                    env: [String: String],
                                    processRunner: ProcessRunner) async -> [AgentModelOption] {
        let stdout: Data?
        do {
            let result = try await processRunner.run(
                executable: executable,
                arguments: ["models"],
                env: env
            )
            stdout = result.stdout
        } catch {
            stdout = try? await processRunner.run(
                executable: executable,
                arguments: ["--list-models"],
                env: env
            ).stdout
        }
        guard let stdout else { return [] }
        return CursorModelCatalog.parse(stdout)
    }
}

private final class CursorModelCache: @unchecked Sendable {
    private let lock = NSLock()
    private var models: [AgentModelOption]

    init(models: [AgentModelOption]) {
        self.models = models
    }

    func snapshot() -> [AgentModelOption] {
        lock.lock()
        defer { lock.unlock() }
        return models
    }

    func replace(with models: [AgentModelOption]) {
        lock.lock()
        self.models = models
        lock.unlock()
    }
}
