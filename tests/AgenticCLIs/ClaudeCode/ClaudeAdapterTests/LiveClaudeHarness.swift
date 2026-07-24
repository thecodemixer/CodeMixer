import Foundation
import AgentCore
import AgentProtocol
import ClaudeCode
import AgentTestSupport

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
struct LiveClaudeHarness {

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

    private let environment: any AgentEnvironment
    private let fileSystem: any FileSystem

    init(environment: any AgentEnvironment = SystemEnvironment(),
         fileSystem: any FileSystem = SystemFileSystem()) {
        self.environment = environment
        self.fileSystem = fileSystem
    }

    // MARK: - Gating

    static let enableVariable = "CODEMIXER_LIVE_CLAUDE"
    static let workspaceVariable = "CODEMIXER_LIVE_WORKSPACE"
    /// Extra opt-in for `runResumeHangDiagnostic` — keep off for normal live runs.
    static let resumeDiagnosticVariable = "CODEMIXER_LIVE_CLAUDE_RESUME_DIAG"

    /// Returns whether live Claude integration should run in this process.
    static func isEnabled(environment: any AgentEnvironment = SystemEnvironment()) -> Bool {
        envVariable(enableVariable, environment: environment) == "1"
    }

    /// Returns whether the resume TUI-row diagnostic should run.
    static func isResumeDiagnosticEnabled(environment: any AgentEnvironment = SystemEnvironment()) -> Bool {
        isEnabled(environment: environment)
            && envVariable(resumeDiagnosticVariable, environment: environment) == "1"
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
            workspace: TestPaths.underTemporary("codemixer-live"),
            resumeSessionID: resumeSessionID,
            permissionMode: permissionMode
        )
        let argv = adapter.buildLaunchArgv(context: context)
        let forbidden = ["--print", "-p", "--input-format", "--output-format", "stream-json"]
        return argv.first == "claude" && !forbidden.contains(where: { argv.contains($0) })
    }

    // MARK: - Drive

    func runTurn(_ configuration: Configuration) async throws -> TurnResult {
        let engine = AgentEngine(seams: .live)
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

    /// Fresh turn, then `--resume` the same session and send again — mirrors
    /// opening an existing Claude session in the sidebar (history + follow-up).
    struct ResumeLoadResult: Sendable {
        let priorSessionID: String
        let reloadedEvents: [AgentEvent]
        let sawPriorUserTurn: Bool
        let sawPriorAssistantFinal: Bool
        let followUpAssistantText: String?
    }

    /// Fresh turn, then `--resume` the same session and send again — mirrors
    /// opening an existing Claude session in the sidebar.
    func runResumedTurn(_ configuration: Configuration) async throws -> TurnResult {
        let load = try await runFreshProcessResume(configuration)
        return TurnResult(events: load.reloadedEvents,
                          sessionID: load.priorSessionID,
                          transcriptURL: ClaudeProjectPaths.transcriptURL(
                            sessionID: load.priorSessionID,
                            workspace: configuration.workspace,
                            claudeDirectory: environment.claudeDirectory
                          ),
                          billingMarkers: nil,
                          finalAssistantText: load.followUpAssistantText,
                          finalAssistantTextCount: load.reloadedEvents.reduce(into: 0) { count, event in
                              if case .assistantText(_, _, _, true) = event { count += 1 }
                          })
    }

    /// Seed → shutdown → `--resume` — asserts transcript history replay, then
    /// a follow-up prompt (same shape as Cursor/Codex live resume loads).
    func runFreshProcessResume(_ configuration: Configuration) async throws -> ResumeLoadResult {
        let first = try await runTurn(configuration)
        guard let sessionID = first.sessionID, !sessionID.isEmpty else {
            throw LiveClaudeHarnessError.hookSessionTimedOut
        }

        let engine = AgentEngine(seams: .live)
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

        try await engine.start(adapter: adapter,
                               workspace: configuration.workspace,
                               resumeSessionID: sessionID)

        // Prefer a real hook SessionStart (model set). Bootstrap also publishes
        // `sessionStarted(resumeID)` with `model: nil` the instant the engine
        // starts — matching that alone races the first prompt ahead of the
        // ready gate's useful work.
        let sawHookSession = await livePollUntil(timeout: configuration.hookSessionTimeout) {
            if await sink.hasHookSessionStarted() { return true }
            return await sink.hasSessionStarted(sessionID: sessionID)
        }
        guard sawHookSession else {
            await engine.shutdown(reason: .naturalExit)
            throw LiveClaudeHarnessError.hookSessionTimedOut
        }

        // Transcript tailer replays prior turns after bind; wait before follow-up.
        let historyReady = await livePollUntil(timeout: configuration.assistantTextTimeout) {
            let user = await sink.containsUserTurn(matching: configuration.prompt)
            let assistant = await sink.containsFinalAssistantText(matching: configuration.expectedFinalSubstring)
            return user && assistant
        }
        let sawUser = await sink.containsUserTurn(matching: configuration.prompt)
        let sawAssistant = await sink.containsFinalAssistantText(matching: configuration.expectedFinalSubstring)
        guard historyReady else {
            let events = await sink.snapshot()
            await engine.shutdown(reason: .naturalExit)
            throw LiveClaudeHarnessError.historyLoadTimedOut(
                events: events,
                sessionID: sessionID,
                detail: "missing replayed user/assistant (user=\(sawUser), assistant=\(sawAssistant))"
            )
        }

        // Give Claude time to paint resumed history before the follow-up write.
        // The engine also gates on ready-prompt scrape / post-SessionStart
        // fallback; this mirrors the fresh-turn settle delay.
        try await Task.sleep(for: configuration.sessionReadyDelay)

        let resumePrompt = "Reply with exactly: resume-pong"
        try await engine.send(.sendPrompt(text: resumePrompt, attachments: []))

        let sawAssistantText = await livePollUntil(timeout: configuration.assistantTextTimeout) {
            await sink.containsFinalAssistantText(matching: "resume-pong")
        }

        let events = await sink.snapshot()
        let followUpText: String?
        if let matched = await sink.latestFinalAssistantTextMatching("resume-pong") {
            followUpText = matched
        } else {
            followUpText = await sink.latestFinalAssistantText()
        }
        await engine.shutdown(reason: .naturalExit)

        guard sawAssistantText else {
            let transcriptURL = ClaudeProjectPaths.transcriptURL(
                sessionID: sessionID,
                workspace: configuration.workspace,
                claudeDirectory: environment.claudeDirectory
            )
            throw LiveClaudeHarnessError.assistantTextTimedOut(events: events,
                                                               transcriptURL: transcriptURL)
        }

        return ResumeLoadResult(
            priorSessionID: sessionID,
            reloadedEvents: events,
            sawPriorUserTurn: sawUser,
            sawPriorAssistantFinal: sawAssistant,
            followUpAssistantText: followUpText
        )
    }

    /// Manual resume-hang probe — seed a turn, `--resume`, then dump SwiftTerm
    /// rows once per second around the follow-up write.
    ///
    /// Use this when a live resume stops accepting prompts (swallowed PTY
    /// write, recovery Enter-loop, ready-gate timing). It is **not** an
    /// assertion suite: it always completes after the dump window and prints
    /// `DIAG …` lines for eyeballing. Gate with
    /// `CODEMIXER_LIVE_CLAUDE_RESUME_DIAG=1` (in addition to
    /// `CODEMIXER_LIVE_CLAUDE=1`) so normal live runs stay cheap.
    ///
    /// What to look for in the dump:
    /// - `ready` / `unsubmitted` should reflect the **last** `❯` / `>` row only
    ///   (history still paints earlier `❯ <old text>` lines).
    /// - After `DIAG sending …`, the live input row should show the follow-up
    ///   text briefly, then clear; `DIAG finals=` should include that reply.
    /// - If `unsubmitted` stays true while the last row is an empty `❯`, the
    ///   detector is matching history again — that is the 2026-07 resume hang.
    func runResumeHangDiagnostic(_ configuration: Configuration) async throws {
        let first = try await runTurn(configuration)
        guard let sessionID = first.sessionID, !sessionID.isEmpty else {
            throw LiveClaudeHarnessError.hookSessionTimedOut
        }

        let engine = AgentEngine(seams: .live)
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

        try await engine.start(adapter: adapter,
                               workspace: configuration.workspace,
                               resumeSessionID: sessionID)

        // Prefer hook SessionStart (model set). Bootstrap also publishes the
        // resume id with `model: nil` immediately — useful for UI unlock, not
        // for deciding Claude's TUI is ready.
        let sawHook = await livePollUntil(timeout: configuration.hookSessionTimeout) {
            await sink.hasHookSessionStarted()
        }
        print("DIAG hookSession=\(sawHook) session=\(sessionID)")

        let followUp = "Reply with exactly: resume-pong"
        for i in 0..<24 {
            let snap = await engine.terminalSnapshotText()
            let rows = snap.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
            let sample = Self.diagnoseClaudePromptRows(rows)
            print(
                "DIAG t=\(i)s ready=\(sample.ready) unsubmitted=\(sample.unsubmitted) interesting=\(sample.interesting.suffix(8))"
            )
            if i == 4 {
                print("DIAG sending \(followUp)")
                try await engine.send(.sendPrompt(text: followUp, attachments: []))
            }
            try await Task.sleep(for: .seconds(1))
        }

        let events = await sink.snapshot()
        let finals = events.compactMap { event -> String? in
            if case .assistantText(_, _, let text, true) = event { return text }
            return nil
        }
        print("DIAG finals=\(finals)")
        print("DIAG eventTail=\(events.suffix(12).map { String(describing: $0).prefix(90) })")
        await engine.shutdown(reason: .naturalExit)
    }

    /// Classifies live input via `ClaudeTerminalInputClassification` so DIAG
    /// dumps stay aligned with `ClaudeAdapter.classifyTerminalInput`.
    private static func diagnoseClaudePromptRows(_ rows: [String]) -> (
        ready: Bool,
        unsubmitted: Bool,
        interesting: [String]
    ) {
        let state = ClaudeTerminalInputClassification.classify(rows)
        let normalized = rows.map { row in
            row.replacingOccurrences(of: "\u{0000}", with: "")
                .replacingOccurrences(of: "\u{00A0}", with: " ")
                .trimmingCharacters(in: .whitespacesAndNewlines)
        }
        let interesting = normalized.filter { t in
            t.contains("❯") || t.hasPrefix(">") || t.lowercased().contains("shortcut")
                || t.localizedCaseInsensitiveContains("pong")
                || t.localizedCaseInsensitiveContains("resume")
                || t.localizedCaseInsensitiveContains("trust")
        }
        return (state == .ready, state == .unsubmitted, interesting)
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
        let shell = URL(fileURLWithPath: environment.processEnvironment()["SHELL"] ?? SystemPaths.zsh.path)
        let resolved = ResolvedEnvironment(variables: environment.processEnvironment(), shell: shell)
        return try? ClaudeBinaryLocator(fileSystem: fileSystem).locate(env: resolved)
    }
}

enum LiveClaudeHarnessError: Error, Sendable, CustomStringConvertible {
    case hookSessionTimedOut
    case assistantTextTimedOut(events: [AgentEvent], transcriptURL: URL?)
    case historyLoadTimedOut(events: [AgentEvent], sessionID: String?, detail: String)

    var description: String {
        switch self {
        case .hookSessionTimedOut:
            return "timed out waiting for hook SessionStart with session id + model"
        case .assistantTextTimedOut(let events, let transcriptURL):
            let tail = events.suffix(8).map { String(describing: $0) }.joined(separator: " | ")
            let transcript = transcriptURL?.path ?? "n/a"
            return "timed out waiting for final assistantText (transcript=\(transcript); tail=\(tail))"
        case .historyLoadTimedOut(let events, let sessionID, let detail):
            let tail = events.suffix(8).map { String(describing: $0) }.joined(separator: " | ")
            let session = sessionID ?? "n/a"
            return "timed out waiting for resumed transcript history (session=\(session); \(detail); tail=\(tail))"
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

    func hasSessionStarted(sessionID expected: String) -> Bool {
        events.contains {
            if case .sessionStarted(let id, _, _) = $0 {
                return id == expected
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

    func containsUserTurn(matching substring: String) -> Bool {
        events.contains {
            if case .userTurn(_, let text) = $0 {
                return text.localizedCaseInsensitiveContains(substring)
            }
            return false
        }
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

    func latestFinalAssistantTextMatching(_ substring: String) -> String? {
        for event in events.reversed() {
            if case .assistantText(_, _, let text, let isFinal) = event,
               isFinal,
               text.localizedCaseInsensitiveContains(substring) {
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
