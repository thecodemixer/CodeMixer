import Foundation
import AgentCore
import AgentProtocol

/// Mutable flag shared between the hook task and TUI-fallback task inside
/// `makeEventStream`: monotonic false→true once any hook fires, after which
/// the TUI scraper stops running. Lock-backed rather than
/// `nonisolated(unsafe)` so both accesses are memory-safe under strict
/// concurrency; the TUI task can still observe the old value for one more
/// poll right as a hook fires — that race is tolerated, not eliminated, and
/// harmless because `ClaudeTUIFallback.seen` dedupes any resulting overlap.
private final class HooksActiveFlag: @unchecked Sendable {
    private let lock = NSLock()
    private var isActive = false

    var active: Bool {
        lock.lock()
        defer { lock.unlock() }
        return isActive
    }

    func activate() {
        lock.lock()
        defer { lock.unlock() }
        isActive = true
    }
}

/// The Claude Code adapter — v1's only adapter, the reference implementation
/// of `AgentAdapter`.
public final class ClaudeAdapter: AgentAdapter, @unchecked Sendable {

    public let id: AgentID = .claudeCode
    public let displayName = "Claude Code"
    public let iconSymbol = "sparkles"

    public var capabilities: AgentCapabilities {
        [.hooksOverUDS, .transcriptJSONL, .ptyTUIFallback,
         .permissionPrompts, .resumableSessions]
    }

    public var transportDescriptor: AgentTransportDescriptor { .interactiveTerminal }

    private let binaryLocator: ClaudeBinaryLocator
    private let hookDecoder: ClaudeHookDecoder
    private let environment: any AgentEnvironment
    private let fileSystem: any FileSystem
    private let clock: any AgentClock
    private let random: any RandomSource
    private let processRunner: ProcessRunner
    private let modelCache: AgentModelCatalogCache

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
        self.binaryLocator = ClaudeBinaryLocator(fileSystem: fileSystem)
        self.hookDecoder = ClaudeHookDecoder(clock: clock, random: random)
        self.modelCache = AgentModelCatalogCache(models: initialModels)
    }

    // MARK: - Discovery & launch

    public func locateBinary(env: ResolvedEnvironment) async throws -> URL {
        do {
            return try binaryLocator.locate(env: env)
        } catch let error as ClaudeBinaryLocator.LocateError {
            switch error {
            case .notFound(let checked):
                throw AgentError.binaryNotFound(agentID: id,
                                                hint: "Install with `npm install -g @anthropic-ai/claude-code`. Checked: \(checked.prefix(3).joined(separator: ", "))…")
            }
        }
    }

    public func defaultEnvOverrides() -> [String: String] {
        [
            "TERM": "xterm-256color",
            "CLAUDE_CODE_DISABLE_ALTERNATE_SCREEN": "1",
            "FORCE_COLOR": "1",
        ]
    }

    public func buildLaunchArgv(context: LaunchContext) -> [String] {
        var argv = ["claude"]
        if context.permissionMode != .default {
            argv += ["--permission-mode", context.permissionMode.rawValue]
        }
        if let resume = context.resumeSessionID {
            argv += ["--resume", resume]
        }
        // Hook socket is injected via settings.local.json, not flags.
        return argv
    }

    // MARK: - Authentication

    public func authStatus(env: ResolvedEnvironment) async -> AuthStatus {
        // Best-effort probe. Failures map to `.unknown` so we don't gate launch
        // behind an advisory check.
        guard let binary = try? binaryLocator.locate(env: env) else { return .unknown }
        guard let result = try? await processRunner.run(executable: binary,
                                                        arguments: ["auth", "status", "--json"],
                                                        env: env.variables) else { return .unknown }
        struct Body: Decodable { let authenticated: Bool?; let account: String? }
        guard let body = try? JSONDecoder().decode(Body.self, from: result.stdout) else { return .unknown }
        if body.authenticated == true { return .authenticated(account: body.account) }
        return .unauthenticated
    }

    // MARK: - Event stream

    public func makeEventStream(inputs: AgentInputs) -> AsyncStream<AgentEvent> {
        AsyncStream<AgentEvent>(bufferingPolicy: .bufferingNewest(StreamBufferDefaults.adapterEvents)) { continuation in
            let tailer = ClaudeTranscriptTailer(claudeDirectory: environment.claudeDirectory,
                                                workspace: inputs.workspace,
                                                initialSessionID: inputs.resumeSessionID,
                                                replayUserTurns: inputs.resumeSessionID != nil,
                                                fileSystem: fileSystem,
                                                clock: clock,
                                                random: random)
            let tuiFallback = ClaudeTUIFallback()
            // Tracks whether at least one hook has fired this session. When true,
            // the TUI scraper is suppressed — hooks are the authoritative source.
            let hooksFlag = HooksActiveFlag()

            // `tailer.start()` is the one dependency both the hook task (needs the
            // tailer ready before binding session/transcript) and the transcript
            // bridge task (forwards its stream) wait on — kept here rather than
            // inside either builder since both share the same `Task` handle.
            let transcriptStream = Task<AsyncStream<AgentEvent>, Never> {
                await tailer.start()
            }

            let hookTask = makeHookTask(inputs: inputs,
                                        tailer: tailer,
                                        transcriptStream: transcriptStream,
                                        hooksFlag: hooksFlag,
                                        continuation: continuation)
            let sessionIDTask = makeSessionIDTask(inputs: inputs, tailer: tailer)
            let transcriptBridgeTask = makeTranscriptBridgeTask(transcriptStream: transcriptStream,
                                                                continuation: continuation)
            let tuiTask = makeTUITask(inputs: inputs,
                                      tuiFallback: tuiFallback,
                                      hooksFlag: hooksFlag,
                                      continuation: continuation)

            continuation.onTermination = { _ in
                hookTask.cancel()
                sessionIDTask.cancel()
                transcriptBridgeTask.cancel()
                tuiTask.cancel()
                Task { await tailer.stop() }
                Task { await tuiFallback.reset() }
            }
        }
    }

    /// Consumes hook-socket requests: binds the transcript tailer to the
    /// session/transcript path each hook advertises, drains the tailer on
    /// `Stop`/`SubagentStop` and strips any `assistantText` the transcript
    /// already emitted (so the hook's Stop summary doesn't duplicate it),
    /// yields every decoded event, and acks the hook (except permission
    /// requests, which the engine's permission-port answers instead).
    private func makeHookTask(inputs: AgentInputs,
                              tailer: ClaudeTranscriptTailer,
                              transcriptStream: Task<AsyncStream<AgentEvent>, Never>,
                              hooksFlag: HooksActiveFlag,
                              continuation: AsyncStream<AgentEvent>.Continuation) -> Task<Void, Never> {
        let hookDecoder = self.hookDecoder
        return Task {
            guard let hookHandle = inputs.hookSocket else { return }
            for await request in hookHandle.incoming {
                _ = await transcriptStream.value
                hooksFlag.activate()
                if let sessionID = Self.sessionID(fromHookPayload: request.jsonPayload) {
                    await tailer.bind(sessionID: sessionID)
                }
                if let transcriptURL = Self.transcriptURL(fromHookPayload: request.jsonPayload) {
                    await tailer.bind(transcriptURL: transcriptURL)
                }
                if request.eventName == "Stop" || request.eventName == "SubagentStop" {
                    await tailer.drain()
                }
                var events = hookDecoder.events(from: request)
                if request.eventName == "Stop" || request.eventName == "SubagentStop",
                   await tailer.hasEmittedAssistantText() {
                    events.removeAll { if case .assistantText = $0 { return true }; return false }
                }
                for event in events {
                    if case .sessionStarted(let id, _, _) = event {
                        await tailer.bind(sessionID: id)
                    }
                    continuation.yield(event)
                    // Hook protocol requires a JSON acknowledgement; an
                    // empty object is always valid for non-permission events.
                    if case .permissionRequest = event {
                        // Caller will respond via the engine's permission-port.
                    } else {
                        await hookHandle.respond(request.id, Data("{}".utf8))
                    }
                }
            }
        }
    }

    /// Rebinds the transcript tailer whenever the engine assigns a new
    /// session id (e.g. on first turn, before any hook has fired).
    private func makeSessionIDTask(inputs: AgentInputs,
                                   tailer: ClaudeTranscriptTailer) -> Task<Void, Never> {
        Task {
            for await sid in inputs.sessionID {
                await tailer.bind(sessionID: sid)
            }
        }
    }

    /// Forwards every event the transcript tailer produces to the adapter's
    /// output stream once the tailer has started.
    private func makeTranscriptBridgeTask(transcriptStream: Task<AsyncStream<AgentEvent>, Never>,
                                          continuation: AsyncStream<AgentEvent>.Continuation) -> Task<Void, Never> {
        Task {
            let stream = await transcriptStream.value
            for await event in stream {
                continuation.yield(event)
            }
        }
    }

    /// Polls the headless terminal framebuffer on the same cadence as the
    /// engine heartbeat poll. Runs only when hooks haven't been confirmed
    /// active — once the hook channel fires, `hooksFlag.active` suppresses
    /// this path so we never double-emit the same information from two
    /// sources.
    private func makeTUITask(inputs: AgentInputs,
                             tuiFallback: ClaudeTUIFallback,
                             hooksFlag: HooksActiveFlag,
                             continuation: AsyncStream<AgentEvent>.Continuation) -> Task<Void, Never> {
        Task {
            while !Task.isCancelled {
                try? await Task.sleep(for: ActivityTiming.noEventPollInterval)
                guard shouldScrapeTUI(hooksActive: hooksFlag.active) else { continue }
                let rows = await inputs.terminal?.snapshotRows() ?? []
                let snapshot = TerminalSnapshot(
                    lines: rows.enumerated().map { TerminalLine(text: $0.element, row: $0.offset) }
                )
                let tuiEvents = await tuiFallback.ingest(snapshot: snapshot)
                for event in tuiEvents { continuation.yield(event) }
            }
        }
    }

    private static func sessionID(fromHookPayload data: Data) -> String? {
        struct Body: Decodable { let session_id: String? }
        return (try? JSONDecoder().decode(Body.self, from: data))?.session_id
    }

    private static func transcriptURL(fromHookPayload data: Data) -> URL? {
        struct Body: Decodable { let transcript_path: String? }
        guard let path = (try? JSONDecoder().decode(Body.self, from: data))?.transcript_path,
              !path.isEmpty else { return nil }
        return URL(fileURLWithPath: path)
    }

    // MARK: - Transcript management

    public func truncateTranscript(afterUserTurnID turnID: String,
                                   sessionID: String,
                                   workspace: URL) async -> Bool {
        let jsonlURL = ClaudeProjectPaths.transcriptURL(sessionID: sessionID,
                                                        workspace: workspace,
                                                        claudeDirectory: environment.claudeDirectory)

        guard let data = try? fileSystem.readData(at: jsonlURL),
              let text = String(data: data, encoding: .utf8) else { return false }

        var keepLines: [Substring] = []
        var foundTurn = false
        for line in text.split(separator: "\n", omittingEmptySubsequences: false) {
            keepLines.append(line)
            // Match by parsing each JSONL record and comparing the `uuid` field exactly.
            // A plain `contains` check would produce false positives if the UUID happened
            // to appear inside a message body or a file path in the same record.
            if let lineData = String(line).data(using: .utf8),
               let record = try? JSONDecoder().decode(TranscriptBoundary.self, from: lineData),
               record.uuid == turnID {
                foundTurn = true
                break
            }
        }
        guard foundTurn else { return false }

        let truncated = keepLines.joined(separator: "\n")
        do {
            try fileSystem.writeAtomically(Data(truncated.utf8), to: jsonlURL)
            return true
        } catch {
            return false
        }
    }

    private struct TranscriptBoundary: Decodable {
        let uuid: String?
    }

    // MARK: - Input encoding

    public func classifyTerminalInput(rows: [String]) -> TerminalInputState {
        ClaudeTerminalInputClassification.classify(rows)
    }

    public func encodeUserPrompt(_ text: String) -> Data {
        ClaudeInputEncoding.userPrompt(text)
    }

    /// Warm session switch inside a live Claude PTY (`/resume <id>`), matching
    /// Codex/ACP in-process resume so the sticky pool does not respawn Claude
    /// when the sidebar picks another chat in the same project.
    public func encodeResumeSession(sessionID: String) -> Data? {
        let trimmed = sessionID.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        return ClaudeInputEncoding.userPrompt("/resume \(trimmed)")
    }

    public func cancelSequence() -> Data {
        ClaudeInputEncoding.cancelSequence()
    }

    public func encodePermissionResponse(_ decision: PermissionDecision,
                                         for prompt: PermissionPrompt) -> PermissionResponseDelivery {
        if prompt.toolName == ClaudeTUIFallback.workspaceTrustToolName {
            let key = decision == .deny ? "2\r" : "1\r"
            return .writePTY(Data(key.utf8))
        }
        return ClaudeInputEncoding.permissionResponse(decision)
    }

    // MARK: - Slash commands & sessions

    public var slashCommandCatalog: [SlashCommand] { ClaudeSlashCommands.builtIn }

    public func availableModels() -> [AgentModelOption] {
        modelCache.snapshot()
    }

    public func modelCatalogRefreshKind() -> ModelCatalogRefreshKind {
        .manual(detail: ClaudeModelCatalog.manualRefreshDetail)
    }

    public func refreshModelCatalog() async throws -> [AgentModelOption] {
        let env = await ShellEnvironmentResolver(
            environment: environment,
            processRunner: processRunner
        ).resolve()
        let binary = try await locateBinary(env: env)
        let discoveryEnv = ResolvedEnvironment(
            variables: env.withOverrides(defaultEnvOverrides()),
            shell: env.shell
        )
        let models = try await ClaudeModelCatalog.discover(
            executable: binary,
            env: discoveryEnv,
            processRunner: processRunner
        )
        modelCache.replace(with: models)
        return models
    }

    /// Seeds the in-memory catalog from workspace cache without a live probe.
    public func seedModelCatalog(_ models: [AgentModelOption]) {
        modelCache.replace(with: models)
    }

    public func availableAgentModes() -> [AgentModeOption] {
        [
            AgentModeOption(
                id: "agent",
                label: "Agent",
                selectCommands: [
                    .setPermissionMode(.default),
                    .setAgentMode(id: AgentModeCommandID.thinkOff),
                    .setAgentMode(id: AgentModeCommandID.reviewOff),
                ]
            ),
            AgentModeOption(
                id: "think",
                label: "Think",
                selectCommands: [
                    .setAgentMode(id: AgentModeCommandID.think),
                    .setAgentMode(id: AgentModeCommandID.reviewOff),
                ]
            ),
            AgentModeOption(
                id: "review",
                label: "Review",
                selectCommands: [
                    .setAgentMode(id: AgentModeCommandID.thinkOff),
                    .setAgentMode(id: AgentModeCommandID.review),
                ]
            ),
        ]
    }

    public func enumerateProjectCommands(workspace: URL) async -> [SlashCommand] {
        ClaudeSlashCommands.enumerateProjectCommands(workspace: workspace,
                                                     claudeDirectory: environment.claudeDirectory,
                                                     fileSystem: fileSystem)
    }

    public func listResumableSessions(workspace: URL) async -> [SessionSummary] {
        ClaudeSessionLister.summaries(workspace: workspace,
                                      claudeDirectory: environment.claudeDirectory,
                                      fileSystem: fileSystem)
    }

    public func resumeArgvAddition(sessionID: String) -> [String] {
        ["--resume", sessionID]
    }

    // MARK: - Hook configuration

    public func installHookConfiguration(socketPath: String,
                                         workspace: URL,
                                         fileSystem: any FileSystem) async throws {
        try ClaudeHookInstaller(fileSystem: fileSystem)
            .install(socketPath: socketPath, into: workspace)
    }
}

func shouldScrapeTUI(hooksActive: Bool) -> Bool {
    !hooksActive
}
