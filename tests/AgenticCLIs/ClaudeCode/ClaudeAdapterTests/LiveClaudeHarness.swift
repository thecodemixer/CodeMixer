import Foundation
import AgentCore
import AgentProtocol
import ClaudeCode

/// Opt-in harness for driving the production `ClaudeAdapter` + `AgentEngine`
/// path against a logged-in `claude` binary (interactive PTY billing — no `-p`).
///
/// Enable with:
///
/// ```bash
/// CODEMIXER_LIVE_CLAUDE=1 swift test --no-parallel --filter LiveClaudeIntegrationTests
/// ```
///
/// See `tests/AgenticCLIs/README.md` for full usage.
///
/// Optional:
///
/// - `CODEMIXER_LIVE_WORKSPACE` — trusted workspace directory (defaults to the
///   process current working directory, usually the repo root under `swift test`).
/// - `CLAUDE_BIN` — override the `claude` executable path.
///
/// The harness waits for hook `SessionStart`, auto-approves workspace-trust
/// prompts, pauses for the TUI prompt row, sends one turn, and can verify
/// transcript billing markers (`entrypoint: cli`, not `sdk-cli`).
struct LiveClaudeHarness: Sendable {

    struct Configuration: Sendable {
        var workspace: URL
        var prompt: String
        var expectedFinalSubstring: String
        var sessionReadyDelay: Duration
        var hookSessionTimeout: Duration
        var assistantTextTimeout: Duration

        init(workspace: URL,
             prompt: String = "Reply with exactly: pong",
             expectedFinalSubstring: String = "pong",
             sessionReadyDelay: Duration = .seconds(6),
             hookSessionTimeout: Duration = .seconds(90),
             assistantTextTimeout: Duration = .seconds(120)) {
            self.workspace = workspace
            self.prompt = prompt
            self.expectedFinalSubstring = expectedFinalSubstring
            self.sessionReadyDelay = sessionReadyDelay
            self.hookSessionTimeout = hookSessionTimeout
            self.assistantTextTimeout = assistantTextTimeout
        }
    }

    struct TurnResult: Sendable {
        let events: [AgentEvent]
        let sessionID: String?
        let transcriptURL: URL?
        let billingMarkers: InteractiveBillingMarkers?
        let finalAssistantText: String?
        let finalAssistantTextCount: Int
    }

    struct InteractiveBillingMarkers: Sendable, Equatable {
        let entrypoint: String
        let promptSource: String?

        var isSubscriptionCLIPath: Bool {
            entrypoint == "cli" && promptSource != "sdk"
        }
    }

    private let seams: Seams
    private let environment: any AgentEnvironment
    private let fileSystem: any FileSystem

    init(seams: Seams = .live,
         environment: any AgentEnvironment = SystemEnvironment(),
         fileSystem: any FileSystem = SystemFileSystem()) {
        self.seams = seams
        self.environment = environment
        self.fileSystem = fileSystem
    }

    // MARK: - Gating

    static let enableVariable = "CODEMIXER_LIVE_CLAUDE"
    static let workspaceVariable = "CODEMIXER_LIVE_WORKSPACE"

    /// Returns whether live Claude integration should run in this process.
    static func isEnabled(environment: any AgentEnvironment = SystemEnvironment()) -> Bool {
        envVariable(enableVariable, environment: environment) == "1"
    }

    /// Human-readable failure when enabled but prerequisites are missing.
    static func prerequisiteFailure(environment: any AgentEnvironment = SystemEnvironment(),
                                    fileSystem: any FileSystem = SystemFileSystem()) -> String? {
        if envVariable("CODEMIXER_FAKE_CLAUDE", environment: environment) == "1" {
            return "unset CODEMIXER_FAKE_CLAUDE for live Claude integration"
        }
        guard locateClaudeBinary(environment: environment, fileSystem: fileSystem) != nil else {
            return "install `claude` on PATH or set CLAUDE_BIN"
        }
        return nil
    }

    static func resolveWorkspace(environment: any AgentEnvironment = SystemEnvironment()) -> URL {
        if let path = envVariable(workspaceVariable, environment: environment), !path.isEmpty {
            return URL(fileURLWithPath: path, isDirectory: true)
        }
        return URL(fileURLWithPath: FileManager.default.currentDirectoryPath, isDirectory: true)
    }

    static func defaultConfiguration(environment: any AgentEnvironment = SystemEnvironment()) -> Configuration {
        Configuration(workspace: resolveWorkspace(environment: environment))
    }

    /// Confirms the adapter never opts into print/SDK billing flags.
    static func launchArgvIsInteractive(permissionMode: PermissionMode = .default,
                                        resumeSessionID: String? = nil) -> Bool {
        let adapter = ClaudeAdapter()
        let context = LaunchContext(
            workspace: URL(fileURLWithPath: "/tmp/codemixer-live"),
            resumeSessionID: resumeSessionID,
            permissionMode: permissionMode
        )
        let argv = adapter.buildLaunchArgv(context: context)
        let forbidden = ["--print", "-p", "--input-format", "--output-format", "stream-json"]
        return argv.first == "claude" && !forbidden.contains(where: { argv.contains($0) })
    }

    // MARK: - Drive

    func runTurn(_ configuration: Configuration) async throws -> TurnResult {
        let engine = AgentEngine(seams: seams)
        await engine.bootstrap()

        let adapter = ClaudeAdapter(environment: environment, fileSystem: fileSystem)
        let sink = LiveClaudeEventSink()
        let sub = await engine.bus.subscribe()
        let ingest = Task { await sink.ingest(sub.stream) }

        var respondedPermissions: Set<UUID> = []
        let approver = Task {
            while !Task.isCancelled {
                if let permissionID = await sink.pendingPermissionID(excluding: respondedPermissions) {
                    respondedPermissions.insert(permissionID)
                    try? await engine.send(.respondToPermission(id: permissionID, decision: .allow))
                }
                try? await Task.sleep(for: .milliseconds(400))
            }
        }

        defer {
            approver.cancel()
            ingest.cancel()
            Task { await engine.bus.unsubscribe(sub.id) }
        }

        try await engine.start(adapter: adapter, workspace: configuration.workspace)

        let sawHookSession = await livePollUntil(timeout: configuration.hookSessionTimeout) {
            await sink.hasHookSessionStarted()
        }
        guard sawHookSession else {
            await engine.shutdown(reason: .naturalExit)
            throw LiveClaudeHarnessError.hookSessionTimedOut
        }

        try await Task.sleep(for: configuration.sessionReadyDelay)

        try await engine.send(.sendPrompt(text: configuration.prompt, attachments: []))

        let sawAssistantText = await livePollUntil(timeout: configuration.assistantTextTimeout) {
            await sink.containsFinalAssistantText(matching: configuration.expectedFinalSubstring)
        }

        let events = await sink.snapshot()
        let sessionID = await sink.hookSessionID()
        let transcriptURL = sessionID.map {
            ClaudeProjectPaths.transcriptURL(sessionID: $0,
                                             workspace: configuration.workspace,
                                             claudeDirectory: environment.claudeDirectory)
        }
        let billingMarkers = transcriptURL.flatMap {
            Self.billingMarkers(in: $0, prompt: configuration.prompt, fileSystem: fileSystem)
        }
        let finalAssistantText = await sink.latestFinalAssistantText()

        await engine.shutdown(reason: .naturalExit)

        guard sawAssistantText else {
            throw LiveClaudeHarnessError.assistantTextTimedOut(events: events,
                                                               transcriptURL: transcriptURL)
        }

        return TurnResult(events: events,
                          sessionID: sessionID,
                          transcriptURL: transcriptURL,
                          billingMarkers: billingMarkers,
                          finalAssistantText: finalAssistantText,
                          finalAssistantTextCount: await sink.finalAssistantTextCount())
    }

    // MARK: - Transcript helpers

    static func billingMarkers(in transcript: URL,
                               prompt: String,
                               fileSystem: any FileSystem = SystemFileSystem()) -> InteractiveBillingMarkers? {
        guard let data = try? fileSystem.readData(at: transcript),
              let text = String(data: data, encoding: .utf8) else { return nil }

        struct UserRecord: Decodable {
            let type: String?
            let entrypoint: String?
            let promptSource: String?
            let message: Message?
            struct Message: Decodable {
                let content: String?
            }
        }

        for line in text.split(separator: "\n", omittingEmptySubsequences: true) {
            guard let record = try? JSONDecoder().decode(UserRecord.self, from: Data(line.utf8)),
                  record.type == "user",
                  let entrypoint = record.entrypoint,
                  record.message?.content?.contains(prompt) == true else { continue }
            return InteractiveBillingMarkers(entrypoint: entrypoint,
                                             promptSource: record.promptSource)
        }
        return nil
    }

    private static func envVariable(_ name: String, environment: any AgentEnvironment) -> String? {
        environment.processEnvironment()[name]
    }

    private static func locateClaudeBinary(environment: any AgentEnvironment,
                                           fileSystem: any FileSystem) -> URL? {
        let shell = URL(fileURLWithPath: environment.processEnvironment()["SHELL"] ?? "/bin/zsh")
        let resolved = ResolvedEnvironment(variables: environment.processEnvironment(), shell: shell)
        return try? ClaudeBinaryLocator(fileSystem: fileSystem).locate(env: resolved)
    }
}

enum LiveClaudeHarnessError: Error, Sendable, CustomStringConvertible {
    case hookSessionTimedOut
    case assistantTextTimedOut(events: [AgentEvent], transcriptURL: URL?)

    var description: String {
        switch self {
        case .hookSessionTimedOut:
            return "timed out waiting for hook SessionStart with session id + model"
        case .assistantTextTimedOut(let events, let transcriptURL):
            let tail = events.suffix(8).map { String(describing: $0) }.joined(separator: " | ")
            let transcript = transcriptURL?.path ?? "n/a"
            return "timed out waiting for final assistantText (transcript=\(transcript); tail=\(tail))"
        }
    }
}

// MARK: - Event sink

actor LiveClaudeEventSink {
    private var events: [AgentEvent] = []

    func ingest(_ stream: AsyncStream<MulticastEventBus.HistoryEntry>) async {
        for await entry in stream {
            events.append(entry.event)
            if events.count > 512 { break }
        }
    }

    func snapshot() -> [AgentEvent] { events }

    func hasHookSessionStarted() -> Bool {
        events.contains {
            if case .sessionStarted(let id, let model, _) = $0 {
                return !id.isEmpty && model != nil
            }
            return false
        }
    }

    func hookSessionID() -> String? {
        for event in events.reversed() {
            if case .sessionStarted(let id, let model, _) = event, !id.isEmpty, model != nil {
                return id
            }
        }
        return nil
    }

    func pendingPermissionID(excluding responded: Set<UUID>) -> UUID? {
        for event in events.reversed() {
            if case .permissionRequest(let prompt) = event, !responded.contains(prompt.id) {
                return prompt.id
            }
        }
        return nil
    }

    func containsFinalAssistantText(matching substring: String) -> Bool {
        events.contains {
            if case .assistantText(_, _, let text, let isFinal) = $0 {
                return isFinal && text.localizedCaseInsensitiveContains(substring)
            }
            return false
        }
    }

    func latestFinalAssistantText() -> String? {
        for event in events.reversed() {
            if case .assistantText(_, _, let text, let isFinal) = event, isFinal {
                return text
            }
        }
        return nil
    }

    func finalAssistantTextCount() -> Int {
        events.reduce(into: 0) { count, event in
            if case .assistantText(_, _, _, let isFinal) = event, isFinal { count += 1 }
        }
    }
}

// MARK: - Polling

func livePollUntil(timeout: Duration,
                   pollInterval: Duration = .milliseconds(100),
                   condition: @escaping @Sendable () async -> Bool) async -> Bool {
    let deadline = ContinuousClock.now + timeout
    while ContinuousClock.now < deadline {
        if await condition() { return true }
        try? await Task.sleep(for: pollInterval)
    }
    return false
}
