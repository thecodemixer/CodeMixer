import Foundation
import AgentClientProtocol
import AgentCore
import AgentProtocol

/// Opt-in harness for driving a user-configured ACP agent server through
/// `ACPAdapter` + `AgentEngine`.
///
/// Enable with:
///
/// ```bash
/// CODEMIXER_LIVE_ACP=1 CODEMIXER_LIVE_ACP_BIN=/path/to/acp-agent \
///   swift test --no-parallel --filter LiveACPIntegrationTests
/// ```
///
/// See `tests/AgenticCLIs/README.md` for full usage.
struct LiveACPHarness {

    struct Configuration: Sendable {
        var workspace: URL
        var executablePath: String
        var arguments: [String]
        var prompt: String
        var expectedFinalSubstring: String
        var sessionReadyTimeout: Duration
        var assistantTextTimeout: Duration

        init(workspace: URL,
             executablePath: String,
             arguments: [String] = [],
             prompt: String = "Reply with exactly: codemixer-acp-pong",
             expectedFinalSubstring: String = "codemixer-acp-pong",
             sessionReadyTimeout: Duration = .seconds(90),
             assistantTextTimeout: Duration = .seconds(120)) {
            self.workspace = workspace
            self.executablePath = executablePath
            self.arguments = arguments
            self.prompt = prompt
            self.expectedFinalSubstring = expectedFinalSubstring
            self.sessionReadyTimeout = sessionReadyTimeout
            self.assistantTextTimeout = assistantTextTimeout
        }
    }

    struct TurnResult: Sendable {
        let events: [AgentEvent]
        let sessionID: String?
        let finalAssistantText: String?
        let finalAssistantTextCount: Int
    }

    private let environment: any AgentEnvironment
    private let fileSystem: any FileSystem

    init(environment: any AgentEnvironment = SystemEnvironment(),
         fileSystem: any FileSystem = SystemFileSystem()) {
        self.environment = environment
        self.fileSystem = fileSystem
    }

    static let enableVariable = "CODEMIXER_LIVE_ACP"
    static let binaryVariable = "CODEMIXER_LIVE_ACP_BIN"
    static let workspaceVariable = "CODEMIXER_LIVE_WORKSPACE"
    static let argumentsVariable = "CODEMIXER_LIVE_ACP_ARGS"

    static func isEnabled(environment: any AgentEnvironment = SystemEnvironment()) -> Bool {
        envVariable(enableVariable, environment: environment) == "1"
    }

    static func prerequisiteFailure(environment: any AgentEnvironment = SystemEnvironment(),
                                    fileSystem: any FileSystem = SystemFileSystem()) -> String? {
        guard let path = envVariable(binaryVariable, environment: environment), !path.isEmpty else {
            return "set CODEMIXER_LIVE_ACP_BIN to an ACP agent-server executable"
        }
        let url = URL(fileURLWithPath: path)
        guard fileSystem.fileExists(at: url) else {
            return "CODEMIXER_LIVE_ACP_BIN not found at \(path)"
        }
        return nil
    }

    static func resolveWorkspace(environment: any AgentEnvironment = SystemEnvironment()) -> URL {
        if let path = envVariable(workspaceVariable, environment: environment), !path.isEmpty {
            return URL(fileURLWithPath: path, isDirectory: true)
        }
        return URL(fileURLWithPath: FileManager.default.currentDirectoryPath, isDirectory: true)
    }

    static func defaultConfiguration(environment: any AgentEnvironment = SystemEnvironment()) -> Configuration? {
        guard let path = envVariable(binaryVariable, environment: environment), !path.isEmpty else {
            return nil
        }
        let args: [String]
        if let raw = envVariable(argumentsVariable, environment: environment), !raw.isEmpty {
            args = raw.split(separator: " ").map(String.init)
        } else {
            args = []
        }
        return Configuration(
            workspace: resolveWorkspace(environment: environment),
            executablePath: path,
            arguments: args
        )
    }

    static func transportIsAgentClientProtocol() -> Bool {
        ACPAdapter(ref: CustomAgentRef(
            id: "live",
            displayName: "Live ACP",
            transport: .agentClientProtocol,
            executablePath: SystemPaths.trueBinary.path,
            arguments: []
        )).transportDescriptor == .agentClientProtocol
    }

    func runTurn(_ configuration: Configuration) async throws -> TurnResult {
        let engine = AgentEngine(seams: .live)
        await engine.bootstrap()

        let adapter = ACPAdapter(
            ref: CustomAgentRef(
                id: "live-acp",
                displayName: "Live ACP",
                transport: .agentClientProtocol,
                executablePath: configuration.executablePath,
                arguments: configuration.arguments
            ),
            environment: environment,
            fileSystem: fileSystem
        )
        let sink = LiveACPEventSink()
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

        let sawSessionOrAuthError = await liveACPPollUntil(timeout: configuration.sessionReadyTimeout) {
            if await sink.hasSessionStarted() { return true }
            return await sink.hasAuthenticationError()
        }
        if await sink.hasAuthenticationError() {
            let events = await sink.snapshot()
            await engine.shutdown(reason: .naturalExit)
            throw LiveACPHarnessError.authenticationRequired(events: events)
        }
        guard sawSessionOrAuthError else {
            let events = await sink.snapshot()
            await engine.shutdown(reason: .naturalExit)
            throw LiveACPHarnessError.sessionStartTimedOut(events: events)
        }

        try await engine.send(.sendPrompt(text: configuration.prompt, attachments: []))

        let sawAssistantText = await liveACPPollUntil(timeout: configuration.assistantTextTimeout) {
            await sink.containsFinalAssistantText(matching: configuration.expectedFinalSubstring)
        }

        let events = await sink.snapshot()
        let sessionID = await sink.sessionID()
        let finalAssistantText = await sink.latestFinalAssistantText()

        await engine.shutdown(reason: .naturalExit)

        guard sawAssistantText else {
            throw LiveACPHarnessError.assistantTextTimedOut(events: events, sessionID: sessionID)
        }

        return TurnResult(
            events: events,
            sessionID: sessionID,
            finalAssistantText: finalAssistantText,
            finalAssistantTextCount: await sink.finalAssistantTextCount()
        )
    }

    private static func envVariable(_ name: String, environment: any AgentEnvironment) -> String? {
        environment.processEnvironment()[name]
    }
}

enum LiveACPHarnessError: Error, CustomStringConvertible {
    case authenticationRequired(events: [AgentEvent])
    case sessionStartTimedOut(events: [AgentEvent])
    case assistantTextTimedOut(events: [AgentEvent], sessionID: String?)

    var description: String {
        switch self {
        case .authenticationRequired(let events):
            return "ACP agent requires authentication before session start (events=\(events.count), tail=\(Self.tail(events)))"
        case .sessionStartTimedOut(let events):
            return "timed out waiting for ACP sessionStarted (events=\(events.count), tail=\(Self.tail(events)))"
        case .assistantTextTimedOut(let events, let sessionID):
            return "timed out waiting for assistantText (session=\(sessionID ?? "nil"), events=\(events.count), tail=\(Self.tail(events)))"
        }
    }

    private static func tail(_ events: [AgentEvent]) -> String {
        events.suffix(8)
            .map { String(describing: $0) }
            .joined(separator: " | ")
    }
}

private actor LiveACPEventSink {
    private var events: [AgentEvent] = []

    func ingest(_ stream: AsyncStream<MulticastEventBus.HistoryEntry>) async {
        for await entry in stream {
            events.append(entry.event)
            if events.count > 512 { break }
        }
    }

    func snapshot() -> [AgentEvent] { events }

    func hasSessionStarted() -> Bool {
        events.contains {
            if case .sessionStarted(let id, _, _) = $0 { return !id.isEmpty }
            return false
        }
    }

    func hasAuthenticationError() -> Bool {
        events.contains {
            if case .error(.authenticationRequired) = $0 { return true }
            return false
        }
    }

    func sessionID() -> String? {
        for event in events.reversed() {
            if case .sessionStarted(let id, _, _) = event, !id.isEmpty { return id }
        }
        return nil
    }

    func pendingPermissionID(excluding responded: Set<UUID>) -> UUID? {
        for event in events {
            if case .permissionRequest(let prompt) = event, !responded.contains(prompt.id) {
                return prompt.id
            }
        }
        return nil
    }

    func containsFinalAssistantText(matching substring: String) -> Bool {
        events.contains {
            if case .assistantText(_, _, let text, true) = $0 {
                return text.localizedCaseInsensitiveContains(substring)
            }
            return false
        }
    }

    func latestFinalAssistantText() -> String? {
        for event in events.reversed() {
            if case .assistantText(_, _, let text, true) = event { return text }
        }
        return nil
    }

    func finalAssistantTextCount() -> Int {
        events.reduce(0) { count, event in
            if case .assistantText(_, _, _, true) = event { return count + 1 }
            return count
        }
    }
}

private func liveACPPollUntil(timeout: Duration, _ condition: @Sendable () async -> Bool) async -> Bool {
    let deadline = ContinuousClock.now + timeout
    while ContinuousClock.now < deadline {
        if await condition() { return true }
        try? await Task.sleep(for: .milliseconds(200))
    }
    return await condition()
}
