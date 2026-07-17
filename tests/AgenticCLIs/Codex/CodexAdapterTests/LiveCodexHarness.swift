import Foundation
import AgentCore
import AgentProtocol
import Codex

/// Opt-in harness for driving the production `CodexAdapter` + `AgentEngine`
/// path against a logged-in `codex` binary (`codex app-server --stdio`).
///
/// Enable with:
///
/// ```bash
/// CODEMIXER_LIVE_CODEX=1 swift test --no-parallel --filter LiveCodexIntegrationTests
/// ```
///
/// See `tests/AgenticCLIs/README.md` for full usage.
///
/// Optional:
///
/// - `CODEMIXER_LIVE_WORKSPACE` — workspace directory (defaults to the process
///   current working directory, usually the repo root under `swift test`).
/// - `CODEX_BIN` — override the `codex` executable path.
struct LiveCodexHarness: Sendable {

    struct Configuration: Sendable {
        var workspace: URL
        var prompt: String
        var expectedFinalSubstring: String
        var threadReadyTimeout: Duration
        var assistantTextTimeout: Duration

        init(workspace: URL,
             prompt: String = "Reply with exactly: codemixer-codex-pong",
             expectedFinalSubstring: String = "codemixer-codex-pong",
             threadReadyTimeout: Duration = .seconds(90),
             assistantTextTimeout: Duration = .seconds(120)) {
            self.workspace = workspace
            self.prompt = prompt
            self.expectedFinalSubstring = expectedFinalSubstring
            self.threadReadyTimeout = threadReadyTimeout
            self.assistantTextTimeout = assistantTextTimeout
        }
    }

    struct TurnResult: Sendable {
        let events: [AgentEvent]
        let threadID: String?
        let finalAssistantText: String?
        let finalAssistantTextCount: Int
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

    static let enableVariable = "CODEMIXER_LIVE_CODEX"
    static let workspaceVariable = "CODEMIXER_LIVE_WORKSPACE"

    /// Returns whether live Codex integration should run in this process.
    static func isEnabled(environment: any AgentEnvironment = SystemEnvironment()) -> Bool {
        envVariable(enableVariable, environment: environment) == "1"
    }

    /// Human-readable failure when enabled but prerequisites are missing.
    static func prerequisiteFailure(environment: any AgentEnvironment = SystemEnvironment(),
                                    fileSystem: any FileSystem = SystemFileSystem()) -> String? {
        guard locateCodexBinary(environment: environment, fileSystem: fileSystem) != nil else {
            return "install `codex` on PATH or set CODEX_BIN"
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

    /// Confirms the adapter stays on the App Server stdio transport path.
    static func launchArgvIsAppServerStdio() -> Bool {
        let adapter = CodexAdapter()
        let context = LaunchContext(workspace: URL(fileURLWithPath: "/tmp/codemixer-live-codex"))
        let argv = adapter.buildLaunchArgv(context: context)
        return argv == ["codex", "app-server", "--stdio"]
    }

    static func transportIsStdioJSONRPC() -> Bool {
        CodexAdapter().transportDescriptor == .stdioJSONRPC
    }

    // MARK: - Drive

    func runTurn(_ configuration: Configuration) async throws -> TurnResult {
        let engine = AgentEngine(seams: seams)
        await engine.bootstrap()

        let adapter = CodexAdapter(environment: environment, fileSystem: fileSystem)
        let sink = LiveCodexEventSink()
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

        let sawThread = await liveCodexPollUntil(timeout: configuration.threadReadyTimeout) {
            await sink.hasCodexThreadStarted()
        }
        guard sawThread else {
            await engine.shutdown(reason: .naturalExit)
            throw LiveCodexHarnessError.threadStartTimedOut
        }

        try await engine.send(.sendPrompt(text: configuration.prompt, attachments: []))

        let sawAssistantText = await liveCodexPollUntil(timeout: configuration.assistantTextTimeout) {
            await sink.containsFinalAssistantText(matching: configuration.expectedFinalSubstring)
        }

        let events = await sink.snapshot()
        let threadID = await sink.codexThreadID()
        let finalAssistantText = await sink.latestFinalAssistantText()

        await engine.shutdown(reason: .naturalExit)

        guard sawAssistantText else {
            throw LiveCodexHarnessError.assistantTextTimedOut(events: events, threadID: threadID)
        }

        return TurnResult(events: events,
                          threadID: threadID,
                          finalAssistantText: finalAssistantText,
                          finalAssistantTextCount: await sink.finalAssistantTextCount())
    }

    private static func envVariable(_ name: String, environment: any AgentEnvironment) -> String? {
        environment.processEnvironment()[name]
    }

    private static func locateCodexBinary(environment: any AgentEnvironment,
                                        fileSystem: any FileSystem) -> URL? {
        let shell = URL(fileURLWithPath: environment.processEnvironment()["SHELL"] ?? "/bin/zsh")
        let resolved = ResolvedEnvironment(variables: environment.processEnvironment(), shell: shell)
        return try? CodexBinaryLocator(environment: environment, fileSystem: fileSystem).locate(env: resolved)
    }
}

enum LiveCodexHarnessError: Error, Sendable, CustomStringConvertible {
    case threadStartTimedOut
    case assistantTextTimedOut(events: [AgentEvent], threadID: String?)

    var description: String {
        switch self {
        case .threadStartTimedOut:
            return "timed out waiting for Codex thread/start sessionStarted with non-empty thread id"
        case .assistantTextTimedOut(let events, let threadID):
            let tail = events.suffix(8).map { String(describing: $0) }.joined(separator: " | ")
            let thread = threadID ?? "n/a"
            return "timed out waiting for final assistantText (thread=\(thread); tail=\(tail))"
        }
    }
}

// MARK: - Event sink

actor LiveCodexEventSink {
    private var events: [AgentEvent] = []

    func ingest(_ stream: AsyncStream<MulticastEventBus.HistoryEntry>) async {
        for await entry in stream {
            events.append(entry.event)
            if events.count > 512 { break }
        }
    }

    func snapshot() -> [AgentEvent] { events }

    func hasCodexThreadStarted() -> Bool {
        events.contains {
            if case .sessionStarted(let id, _, _) = $0 {
                return !id.isEmpty
            }
            return false
        }
    }

    func codexThreadID() -> String? {
        for event in events.reversed() {
            if case .sessionStarted(let id, _, _) = event, !id.isEmpty {
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

func liveCodexPollUntil(timeout: Duration,
                        pollInterval: Duration = .milliseconds(100),
                        condition: @escaping @Sendable () async -> Bool) async -> Bool {
    let deadline = ContinuousClock.now + timeout
    while ContinuousClock.now < deadline {
        if await condition() { return true }
        try? await Task.sleep(for: pollInterval)
    }
    return false
}
