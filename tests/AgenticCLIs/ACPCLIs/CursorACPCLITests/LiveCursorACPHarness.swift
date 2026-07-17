import Foundation
import ACPCLIs
import AgentCore
import AgentProtocol

/// Opt-in driver for Cursor ACP through `CursorACPAdapter` + `AgentEngine`.
struct LiveCursorACPHarness {

    enum ModeKind: String, Sendable, CaseIterable {
        case agent
        case plan
        case ask
        case debug
    }

    enum ModeProbeResult: String, Sendable, Equatable {
        case supported
        case diagnosticOnly
        case unsupported
        case authRequired
        case timedOut
    }

    struct Configuration: Sendable {
        var workspace: URL
        var executablePath: String
        var prompt: String
        var expectedFinalSubstring: String
        var sessionReadyTimeout: Duration
        var modeTimeout: Duration
        var assistantTextTimeout: Duration

        init(workspace: URL,
             executablePath: String,
             prompt: String = "Reply with exactly: codemixer-cursor-acp-pong",
             expectedFinalSubstring: String = "codemixer-cursor-acp-pong",
             sessionReadyTimeout: Duration = .seconds(90),
             modeTimeout: Duration = .seconds(30),
             assistantTextTimeout: Duration = .seconds(120)) {
            self.workspace = workspace
            self.executablePath = executablePath
            self.prompt = prompt
            self.expectedFinalSubstring = expectedFinalSubstring
            self.sessionReadyTimeout = sessionReadyTimeout
            self.modeTimeout = modeTimeout
            self.assistantTextTimeout = assistantTextTimeout
        }
    }

    struct Result: Sendable {
        let events: [AgentEvent]
        let sessionID: String?
        let finalAssistantText: String?
        let modeProbeResults: [ModeKind: ModeProbeResult]
        let cliVersion: String?
    }

    static let enableVariable = "CODEMIXER_LIVE_CURSOR_ACP"
    static let binaryVariables = ["CODEMIXER_LIVE_CURSOR_BIN", "CURSOR_BIN"]
    static let workspaceVariable = "CODEMIXER_LIVE_WORKSPACE"

    static func isEnabled(environment: any AgentEnvironment = SystemEnvironment()) -> Bool {
        environment.processEnvironment()[enableVariable] == "1"
    }

    static func resolveBinaryPath(environment: any AgentEnvironment = SystemEnvironment()) -> String? {
        let env = environment.processEnvironment()
        for key in binaryVariables {
            if let path = env[key], !path.isEmpty { return path }
        }
        return env["PATH"]?
            .split(separator: ":")
            .map { URL(fileURLWithPath: String($0), isDirectory: true)
                .appendingPathComponent("cursor-agent").path }
            .first { FileManager.default.isExecutableFile(atPath: $0) }
            ?? ([
                NSHomeDirectory() + "/.local/bin/cursor-agent",
                "/opt/homebrew/bin/cursor-agent",
                "/usr/local/bin/cursor-agent",
            ].first { FileManager.default.isExecutableFile(atPath: $0) })
    }

    static func prerequisiteFailure(environment: any AgentEnvironment = SystemEnvironment(),
                                    fileSystem: any FileSystem = SystemFileSystem()) -> String? {
        guard let path = resolveBinaryPath(environment: environment) else {
            return "set CURSOR_BIN or CODEMIXER_LIVE_CURSOR_BIN to cursor-agent"
        }
        guard fileSystem.fileExists(at: URL(fileURLWithPath: path)) else {
            return "Cursor binary not found at \(path)"
        }
        return nil
    }

    static func defaultConfiguration(environment: any AgentEnvironment = SystemEnvironment()) -> Configuration? {
        guard let path = resolveBinaryPath(environment: environment) else { return nil }
        let workspace: URL
        if let raw = environment.processEnvironment()[workspaceVariable], !raw.isEmpty {
            workspace = URL(fileURLWithPath: raw, isDirectory: true)
        } else {
            workspace = URL(fileURLWithPath: FileManager.default.currentDirectoryPath, isDirectory: true)
        }
        return Configuration(workspace: workspace, executablePath: path)
    }

    func run(_ configuration: Configuration) async throws -> Result {
        let version = await Self.readVersion(executablePath: configuration.executablePath)
        let env = SystemEnvironment()
        let engine = AgentEngine(seams: .live)
        await engine.bootstrap()

        // Ensure locator finds the opted-in binary even when PATH is thin.
        let adapter = CursorACPAdapter(
            environment: LiveCursorEnvironment(
                base: env,
                overrides: ["CURSOR_BIN": configuration.executablePath]
            ),
            fileSystem: SystemFileSystem()
        )
        let sink = LiveCursorEventSink()
        let sub = await engine.bus.subscribe()
        let ingest = Task { await sink.ingest(sub.stream) }
        var responded: Set<UUID> = []
        let approver = Task {
            while !Task.isCancelled {
                if let id = await sink.pendingPermissionID(excluding: responded) {
                    responded.insert(id)
                    try? await engine.send(.respondToPermission(id: id, decision: .allow))
                }
                try? await Task.sleep(for: .milliseconds(300))
            }
        }
        defer {
            approver.cancel()
            ingest.cancel()
            Task { await engine.bus.unsubscribe(sub.id) }
        }

        try await engine.start(adapter: adapter, workspace: configuration.workspace)

        let ready = await poll(timeout: configuration.sessionReadyTimeout) {
            if await sink.hasAuthenticationError() { return true }
            return await sink.hasNonEmptySession()
        }
        if await sink.hasAuthenticationError() {
            let events = await sink.snapshot()
            await engine.shutdown(reason: .naturalExit)
            throw LiveCursorHarnessError.authenticationRequired(events: events, version: version)
        }
        guard ready else {
            let events = await sink.snapshot()
            await engine.shutdown(reason: .naturalExit)
            throw LiveCursorHarnessError.sessionStartTimedOut(events: events, version: version)
        }

        var modeResults: [ModeKind: ModeProbeResult] = [:]
        // agent / plan / ask via session/set_mode (or slash remapped by adapter)
        for mode in [ModeKind.plan, ModeKind.ask, ModeKind.agent] {
            let before = await sink.eventCount()
            switch mode {
            case .plan:
                try await engine.send(.setPermissionMode(.plan))
            case .ask:
                try await engine.send(.runSlashCommand(name: "/ask", args: []))
            case .agent:
                try await engine.send(.setPermissionMode(.default))
            case .debug:
                break
            }
            let ok = await poll(timeout: configuration.modeTimeout) {
                await sink.hasStatusPhrase(containing: mode.rawValue, after: before)
            }
            modeResults[mode] = ok ? .supported : .timedOut
        }

        // debug is diagnostic-only — expect unsupportedCommand, not a mode update.
        let beforeDebug = await sink.eventCount()
        try await engine.send(.runSlashCommand(name: "/debug", args: []))
        let sawUnsupported = await poll(timeout: .seconds(5)) {
            await sink.hasUnsupportedCommand(after: beforeDebug)
        }
        modeResults[.debug] = sawUnsupported ? .diagnosticOnly : .unsupported

        try await engine.send(.sendPrompt(text: configuration.prompt, attachments: []))
        let sawText = await poll(timeout: configuration.assistantTextTimeout) {
            await sink.containsFinalAssistantText(matching: configuration.expectedFinalSubstring)
        }

        let events = await sink.snapshot()
        let sessionID = await sink.sessionID()
        let finalText = await sink.latestFinalAssistantText()
        await engine.shutdown(reason: .naturalExit)

        guard sawText else {
            throw LiveCursorHarnessError.assistantTextTimedOut(
                events: events,
                sessionID: sessionID,
                version: version,
                modes: modeResults
            )
        }

        return Result(
            events: events,
            sessionID: sessionID,
            finalAssistantText: finalText,
            modeProbeResults: modeResults,
            cliVersion: version
        )
    }

    private static func readVersion(executablePath: String) async -> String? {
        let runner = ProcessRunner()
        do {
            let result = try await runner.run(
                executable: URL(fileURLWithPath: executablePath),
                arguments: ["--version"]
            )
            let text = String(decoding: result.stdout, as: UTF8.self)
                .trimmingCharacters(in: .whitespacesAndNewlines)
            return text.isEmpty ? nil : text
        } catch {
            return nil
        }
    }
}

/// Thin environment overlay so the live harness can pin `CURSOR_BIN`.
private struct LiveCursorEnvironment: AgentEnvironment {
    let base: any AgentEnvironment
    let overrides: [String: String]

    var homeDirectory: URL { base.homeDirectory }
    var appSupportDirectory: URL { base.appSupportDirectory }
    var cachesDirectory: URL { base.cachesDirectory }
    var claudeDirectory: URL { base.claudeDirectory }
    var deviceName: String { base.deviceName }

    func processEnvironment() -> [String: String] {
        var env = base.processEnvironment()
        for (key, value) in overrides { env[key] = value }
        return env
    }
}

enum LiveCursorHarnessError: Error, CustomStringConvertible {
    case authenticationRequired(events: [AgentEvent], version: String?)
    case sessionStartTimedOut(events: [AgentEvent], version: String?)
    case assistantTextTimedOut(events: [AgentEvent],
                               sessionID: String?,
                               version: String?,
                               modes: [LiveCursorACPHarness.ModeKind: LiveCursorACPHarness.ModeProbeResult])

    var description: String {
        switch self {
        case .authenticationRequired(let events, let version):
            return "Cursor ACP authentication required (version=\(version ?? "unknown"), events=\(events.count))"
        case .sessionStartTimedOut(let events, let version):
            return "timed out waiting for Cursor session (version=\(version ?? "unknown"), events=\(events.count))"
        case .assistantTextTimedOut(let events, let sessionID, let version, let modes):
            let modeSummary = modes.map { "\($0.key.rawValue)=\($0.value.rawValue)" }.sorted().joined(separator: ",")
            return "timed out waiting for assistantText (session=\(sessionID ?? "nil"), version=\(version ?? "unknown"), modes=[\(modeSummary)], events=\(events.count))"
        }
    }
}

private actor LiveCursorEventSink {
    private var events: [AgentEvent] = []

    func ingest(_ stream: AsyncStream<MulticastEventBus.HistoryEntry>) async {
        for await entry in stream {
            events.append(entry.event)
            if events.count > 1024 { break }
        }
    }

    func snapshot() -> [AgentEvent] { events }
    func eventCount() -> Int { events.count }

    func hasNonEmptySession() -> Bool {
        events.contains {
            if case .sessionStarted(let id, _, _) = $0 { return !id.isEmpty }
            return false
        }
    }

    func hasAuthenticationError() -> Bool {
        events.contains { if case .error(.authenticationRequired) = $0 { return true }; return false }
    }

    func hasStatusPhrase(containing needle: String, after index: Int) -> Bool {
        events.dropFirst(index).contains {
            if case .statusPhraseChanged(_, let phrase) = $0 {
                return phrase.localizedCaseInsensitiveContains(needle)
            }
            return false
        }
    }

    func hasUnsupportedCommand(after index: Int) -> Bool {
        events.dropFirst(index).contains {
            if case .error(.unsupportedCommand) = $0 { return true }
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
}

private func poll(timeout: Duration, _ condition: @Sendable () async -> Bool) async -> Bool {
    let deadline = ContinuousClock.now + timeout
    while ContinuousClock.now < deadline {
        if await condition() { return true }
        try? await Task.sleep(for: .milliseconds(200))
    }
    return await condition()
}
