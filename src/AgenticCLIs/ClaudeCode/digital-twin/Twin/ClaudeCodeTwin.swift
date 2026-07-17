import Foundation
import AgentCore
import AgentProtocol

/// Deterministic, in-process simulator of `claude` CLI's externally-visible
/// contract.
///
/// `ClaudeCodeTwin` satisfies `AgentAdapter` so the engine can drive it the
/// same way it drives `ClaudeAdapter`. Its purpose is twofold:
///
/// 1. **Testing without the real binary.** `swift test` runs end-to-end
///    turns through the twin on machines that don't have `claude` installed
///    (CI runners, fresh dev boxes).
/// 2. **Executable specification.** The twin is the canonical, runnable
///    statement of what Codemixer expects from Claude Code's hook payloads,
///    transcript JSONL, slash commands, and PTY semantics. When Anthropic
///    changes Claude Code, the twin is updated first; production
///    `ClaudeAdapter` follows. See `src/AgenticCLIs/ClaudeCode/README.md`.
///
/// Twin sources live under `digital-twin/Twin/` alongside the adapter but must
/// not call adapter-only types (`ClaudeHookDecoder`, `ClaudeTranscriptTailer`, …) — parity tests
/// in `ClaudeAdapterTests` validate the contract from the outside.
public final class ClaudeCodeTwin: AgentAdapter, @unchecked Sendable {

    // MARK: - Identity

    public let id: AgentID = .claudeCode
    public let displayName = "Claude Code (digital twin)"
    public let iconSymbol = "sparkles"
    public let capabilities: AgentCapabilities = [
        .hooksOverUDS, .transcriptJSONL, .permissionPrompts, .resumableSessions,
    ]
    public var transportDescriptor: AgentTransportDescriptor { .interactiveTerminal }

    // MARK: - Configuration

    public struct Configuration: Sendable {
        public var sessionID: String
        public var model: String
        public var scenario: ClaudeCodeTwinScenario
        /// Wall-clock per simulated turn step. Tests usually set this to 0.
        public var stepDelay: Duration
        public var runtime: TwinRuntimeSeams

        public init(sessionID: String? = nil,
                    model: String = "claude-sonnet-4-twin",
                    scenario: ClaudeCodeTwinScenario = .textOnly(reply: "Hello from the twin."),
                    stepDelay: Duration = .milliseconds(0),
                    runtime: TwinRuntimeSeams = .live) {
            self.sessionID = sessionID ?? runtime.uuidString()
            self.model = model
            self.scenario = scenario
            self.stepDelay = stepDelay
            self.runtime = runtime
        }
    }

    /// Alias for shared scenario vocabulary (`ClaudeCodeTwinScenario.swift`).
    public typealias Scenario = ClaudeCodeTwinScenario

    public let configuration: Configuration

    public init(configuration: Configuration = Configuration()) {
        self.configuration = configuration
    }

    // MARK: - Discovery & launch
    //
    // The twin doesn't *spawn* anything; the engine still wants a real
    // executable to run under a PTY because PTYHost owns the lifecycle. We
    // return `/usr/bin/true` so the spawn succeeds and exits immediately,
    // and the twin emits its event stream from `makeEventStream` without
    // touching the PTY.

    public func locateBinary(env: ResolvedEnvironment) async throws -> URL {
        URL(fileURLWithPath: "/usr/bin/true")
    }

    public func defaultEnvOverrides() -> [String: String] { [:] }

    public func buildLaunchArgv(context: LaunchContext) -> [String] {
        ["true", "--codemixer-twin", "--session", configuration.sessionID]
    }

    // MARK: - Authentication

    public func authStatus(env: ResolvedEnvironment) async -> AuthStatus {
        if case .needsAuth = configuration.scenario { return .unauthenticated }
        return .authenticated(account: "twin@codemixer.local")
    }

    // MARK: - Event stream
    //
    // The heart of the twin: deterministically emit the same alphabet of
    // `AgentEvent` values the real adapter would have produced for an
    // equivalent turn. We honour `inputs.workspace` so paths in events
    // resolve to the test's temporary directory.

    public func makeEventStream(inputs: AgentInputs) -> AsyncStream<AgentEvent> {
        let cfg = configuration
        return AsyncStream<AgentEvent>(bufferingPolicy: .bufferingNewest(StreamBufferDefaults.transcriptEvents)) { continuation in
            let driver = Task<Void, Never> { [cfg] in
                let twinSession = cfg.sessionID
                continuation.yield(.sessionStarted(sessionID: twinSession,
                                                   model: cfg.model,
                                                   cwd: inputs.workspace))
                await Self.run(scenario: cfg.scenario,
                               sessionID: twinSession,
                               stepDelay: cfg.stepDelay,
                               runtime: cfg.runtime,
                               continuation: continuation)
                continuation.yield(.stopped(reason: .naturalExit))
                continuation.finish()
            }

            continuation.onTermination = { _ in driver.cancel() }
        }
    }

    private static func run(scenario: ClaudeCodeTwinScenario,
                            sessionID: String,
                            stepDelay: Duration,
                            runtime: TwinRuntimeSeams,
                            continuation: AsyncStream<AgentEvent>.Continuation) async {
        if stepDelay > .zero {
            await runtime.sleep(for: stepDelay)
        }

        switch scenario {
        case .textOnly(let reply):
            await emitAssistantText(reply,
                                    continuation: continuation,
                                    stepDelay: stepDelay,
                                    runtime: runtime)

        case .thinkingThenReply(let thinking, let reply):
            let blockID = runtime.uuid()
            let start = runtime.now()
            for chunk in chunked(thinking) {
                continuation.yield(.thinkingChunk(blockID: blockID, delta: chunk))
                if stepDelay > .zero { await runtime.sleep(for: stepDelay) }
            }
            continuation.yield(.thinkingComplete(blockID: blockID,
                                                 duration: .seconds(runtime.now().timeIntervalSince(start))))
            await emitAssistantText(reply,
                                    continuation: continuation,
                                    stepDelay: stepDelay,
                                    runtime: runtime)

        case .withBash(let command, let stdout, let exitCode, let reply):
            let toolID = runtime.uuid()
            let input = ToolInput(summary: "Run: \(command)",
                                  jsonPayload: #"{"command":"\#(command)"}"#)
            continuation.yield(.toolStart(id: toolID.uuidString,
                                          name: "Bash",
                                          input: input,
                                          startedAt: runtime.now()))
            for line in stdout.split(separator: "\n") {
                continuation.yield(.toolProgress(callID: toolID, progress: .bashLine(String(line))))
                if stepDelay > .zero { await runtime.sleep(for: stepDelay) }
            }
            let output = ToolOutput(summary: stdout, jsonPayload: nil,
                                    errorMessage: exitCode == 0 ? nil : "exit \(exitCode)")
            continuation.yield(.toolEnd(id: toolID.uuidString,
                                        success: exitCode == 0,
                                        output: output,
                                        durationMS: 42))
            await emitAssistantText(reply,
                                    continuation: continuation,
                                    stepDelay: stepDelay,
                                    runtime: runtime)

        case .withEdit(let path, let diff, let reply):
            let toolID = runtime.uuid()
            continuation.yield(.toolStart(id: toolID.uuidString,
                                          name: "Edit",
                                          input: ToolInput(summary: "Modify \(path)",
                                                           jsonPayload: #"{"file_path":"\#(path)"}"#),
                                          startedAt: runtime.now()))
            continuation.yield(.toolEnd(id: toolID.uuidString,
                                        success: true,
                                        output: ToolOutput(summary: diff),
                                        durationMS: 12))
            continuation.yield(.fileTouched(URL(fileURLWithPath: path), kind: .hookReported))
            await emitAssistantText(reply,
                                    continuation: continuation,
                                    stepDelay: stepDelay,
                                    runtime: runtime)

        case .permissionPrompt(let tool, let summary, let reply):
            let id = runtime.uuid()
            continuation.yield(.permissionRequest(prompt: PermissionPrompt(
                id: id,
                toolName: tool,
                summary: summary,
                argumentsSummary: #"{}"#,
                requestedAt: runtime.now()
            )))
            // Twin doesn't auto-respond; the test (or UI) calls the
            // engine's `respondToPermission`. After a brief delay, finish
            // with text so a fully-scripted run still terminates.
            await runtime.sleep(for: .milliseconds(50))
            await emitAssistantText(reply,
                                    continuation: continuation,
                                    stepDelay: stepDelay,
                                    runtime: runtime)

        case .needsAuth(let url):
            continuation.yield(.authURL(url))

        case .usageOnly(let inputTokens, let outputTokens, let cost):
            continuation.yield(.usage(tokens: inputTokens + outputTokens, costUSD: cost))

        case .crash(let partial):
            let messageID = runtime.uuid()
            continuation.yield(.textDelta(messageID: messageID, delta: partial))
            continuation.yield(.error(.spawnFailed(errno: 137,
                                                   detail: "twin: simulated crash")))

        case .workspaceTrust:
            continuation.yield(.permissionRequest(prompt: PermissionPrompt(
                id: runtime.uuid(),
                toolName: "WorkspaceTrust",
                summary: "Trust this workspace?",
                argumentsSummary: "{}",
                requestedAt: runtime.now()
            )))

        case .resumeLatePrompt, .resumeStalled, .swallowedEnter:
            await emitAssistantText("Resumed.",
                                    continuation: continuation,
                                    stepDelay: stepDelay,
                                    runtime: runtime)

        case .sequence(let scenarios):
            for sub in scenarios {
                await run(scenario: sub,
                          sessionID: sessionID,
                          stepDelay: stepDelay,
                          runtime: runtime,
                          continuation: continuation)
            }
        }
    }

    private static func emitAssistantText(_ text: String,
                                          continuation: AsyncStream<AgentEvent>.Continuation,
                                          stepDelay: Duration,
                                          runtime: TwinRuntimeSeams) async {
        let messageID = runtime.uuid()
        let blockID = runtime.uuidString()
        for chunk in chunked(text) {
            continuation.yield(.textDelta(messageID: messageID, delta: chunk))
            if stepDelay > .zero { await runtime.sleep(for: stepDelay) }
        }
        continuation.yield(.assistantText(id: messageID.uuidString,
                                          blockID: blockID,
                                          text: text,
                                          isFinal: true))
    }

    private static func chunked(_ text: String, size: Int = 16) -> [String] {
        var out: [String] = []
        var idx = text.startIndex
        while idx < text.endIndex {
            let end = text.index(idx, offsetBy: size, limitedBy: text.endIndex) ?? text.endIndex
            out.append(String(text[idx..<end]))
            idx = end
        }
        return out.isEmpty ? [text] : out
    }

    // MARK: - Input encoding (matches `ClaudeAdapter`)

    public func encodeUserPrompt(_ text: String) -> Data {
        ClaudeInputEncoding.userPrompt(text)
    }

    public func cancelSequence() -> Data {
        ClaudeInputEncoding.cancelSequence()
    }

    public func encodePermissionResponse(_ decision: PermissionDecision,
                                         for prompt: PermissionPrompt) -> PermissionResponseDelivery {
        ClaudeInputEncoding.permissionResponse(decision)
    }

    // MARK: - Slash commands & sessions

    public var slashCommandCatalog: [SlashCommand] { ClaudeCodeTwinSlashCommands.builtIn }
    public func enumerateProjectCommands(workspace: URL) async -> [SlashCommand] { [] }

    public func listResumableSessions(workspace: URL) async -> [SessionSummary] {
        [
            SessionSummary(id: configuration.sessionID,
                           agentID: .claudeCode,
                           workspace: workspace,
                           title: "Twin session",
                           lastActivity: configuration.runtime.now(),
                           messageCount: 0),
        ]
    }

    public func resumeArgvAddition(sessionID: String) -> [String] {
        ["--resume", sessionID]
    }
}
