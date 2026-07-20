import Foundation
import ACPCLIs
import AgentClientProtocol
import AgentCore
import AgentProtocol

/// Opt-in driver for a real ACP binary through `CustomACPAdapter`.
///
/// Gate: `CODEMIXER_LIVE_CUSTOM_ACP=1` and `CODEMIXER_LIVE_ACP_BIN=/path/to/agent`.
struct LiveCustomACPHarness {
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
             arguments: [String] = ["acp"],
             prompt: String = "Reply with exactly: codemixer-custom-acp-pong",
             expectedFinalSubstring: String = "codemixer-custom-acp-pong",
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

    struct Result: Sendable {
        let sessionID: String?
        let finalAssistantText: String?
        let modeIDs: [String]
    }

    static func isEnabled() -> Bool {
        ProcessInfo.processInfo.environment["CODEMIXER_LIVE_CUSTOM_ACP"] == "1"
    }

    static func executablePath() -> String? {
        let env = ProcessInfo.processInfo.environment
        let path = env["CODEMIXER_LIVE_ACP_BIN"] ?? env["CODEMIXER_CUSTOM_ACP_BIN"]
        guard let path, !path.isEmpty else { return nil }
        return path
    }

    func run(_ config: Configuration) async throws -> Result {
        let ref = CustomAgentRef(
            id: "live-custom",
            displayName: "Live Custom ACP",
            transport: .agentClientProtocol,
            executablePath: config.executablePath,
            arguments: config.arguments
        )
        let env = SystemEnvironment()
        let fs = SystemFileSystem()
        let adapter = CustomACPAdapter(
            ref: ref,
            environment: env,
            fileSystem: fs
        )
        let engine = AgentEngine(seams: Seams(
            clock: SystemClock(),
            random: SystemRandomSource(),
            environment: env,
            fileSystem: fs
        ))
        await engine.bootstrap()

        let sink = LiveCustomEventSink()
        let sub = await engine.bus.subscribe()
        let collector = Task { await sink.ingest(sub.stream) }
        defer {
            collector.cancel()
            Task {
                await engine.bus.unsubscribe(sub.id)
                await engine.shutdown(reason: .naturalExit)
            }
        }

        try await engine.start(adapter: adapter, workspace: config.workspace)
        let ready = await pollUntil(timeout: config.sessionReadyTimeout) {
            await sink.sessionID() != nil
        }
        guard ready else {
            throw LiveCustomACPError.timeout("sessionStarted")
        }

        let modeIDs = adapter.availableAgentModes().map(\.id)
        try await engine.send(.sendPrompt(text: config.prompt, attachments: []))
        let sawFinal = await pollUntil(timeout: config.assistantTextTimeout) {
            await sink.finalAssistantText()?.contains(config.expectedFinalSubstring) == true
        }
        guard sawFinal else {
            throw LiveCustomACPError.timeout("assistant final")
        }

        return Result(
            sessionID: await sink.sessionID(),
            finalAssistantText: await sink.finalAssistantText(),
            modeIDs: modeIDs
        )
    }
}

enum LiveCustomACPError: Error {
    case timeout(String)
}

private actor LiveCustomEventSink {
    private var events: [AgentEvent] = []

    func ingest(_ stream: AsyncStream<MulticastEventBus.HistoryEntry>) async {
        for await entry in stream {
            events.append(entry.event)
            if events.count > 512 { break }
        }
    }

    func sessionID() -> String? {
        for event in events.reversed() {
            if case .sessionStarted(let id, _, _) = event, !id.isEmpty {
                return id
            }
        }
        return nil
    }

    func finalAssistantText() -> String? {
        for event in events.reversed() {
            if case .assistantText(_, _, let text, let isFinal) = event, isFinal {
                return text
            }
        }
        return nil
    }
}

private func pollUntil(timeout: Duration, _ condition: @escaping @Sendable () async -> Bool) async -> Bool {
    let deadline = ContinuousClock.now + timeout
    while ContinuousClock.now < deadline {
        if await condition() { return true }
        try? await Task.sleep(for: .milliseconds(100))
    }
    return await condition()
}
