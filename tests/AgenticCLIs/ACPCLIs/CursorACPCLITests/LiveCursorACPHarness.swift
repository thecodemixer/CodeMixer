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
        /// Second same-session prompt — validates warm-path latency + distinct finals.
        var secondPrompt: String
        var expectedSecondFinalSubstring: String
        var sessionReadyTimeout: Duration
        var modeTimeout: Duration
        var assistantTextTimeout: Duration

        init(workspace: URL,
             executablePath: String,
             prompt: String = "Reply with exactly: codemixer-cursor-acp-pong",
             expectedFinalSubstring: String = "codemixer-cursor-acp-pong",
             secondPrompt: String = "Reply with exactly: codemixer-cursor-acp-pong-2",
             expectedSecondFinalSubstring: String = "codemixer-cursor-acp-pong-2",
             sessionReadyTimeout: Duration = .seconds(90),
             modeTimeout: Duration = .seconds(30),
             assistantTextTimeout: Duration = .seconds(120)) {
            self.workspace = workspace
            self.executablePath = executablePath
            self.prompt = prompt
            self.expectedFinalSubstring = expectedFinalSubstring
            self.secondPrompt = secondPrompt
            self.expectedSecondFinalSubstring = expectedSecondFinalSubstring
            self.sessionReadyTimeout = sessionReadyTimeout
            self.modeTimeout = modeTimeout
            self.assistantTextTimeout = assistantTextTimeout
        }
    }

    struct TurnTiming: Sendable, Equatable {
        let duration: Duration
        let finalAssistantID: String?
        let finalAssistantText: String?
    }

    struct Result: Sendable {
        let events: [AgentEvent]
        let sessionID: String?
        let finalAssistantText: String?
        let firstTurn: TurnTiming
        let secondTurn: TurnTiming
        let modeProbeResults: [ModeKind: ModeProbeResult]
        let cliVersion: String?
    }

    struct ResumeLoadResult: Sendable {
        let priorSessionID: String
        let reloadedEvents: [AgentEvent]
        let sawPriorUserTurn: Bool
        let sawPriorAssistantFinal: Bool
        let followUpAssistantText: String?
        let cliVersion: String?
    }

    /// Live streaming cadence for thoughts + assistant chunks (UI streaming check).
    struct StreamingCadenceResult: Sendable {
        let sessionID: String?
        let cliVersion: String?
        let thinkingChunkCount: Int
        let nonFinalAssistantCount: Int
        let distinctNonFinalLengths: [Int]
        /// Wall time from first non-final assistant chunk to last (nil if <2 chunks).
        let assistantStreamSpan: Duration?
        /// Wall time from first thinking chunk to last (nil if <2 chunks).
        let thinkingStreamSpan: Duration?
        let finalAssistantText: String?
        let events: [AgentEvent]
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
                SystemPaths.binary(in: SystemPaths.homebrewBin, named: "cursor-agent").path,
                SystemPaths.binary(in: SystemPaths.usrLocalBin, named: "cursor-agent").path,
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
                try await engine.send(.runSlashCommand(target: .builtin(name: "/ask"), args: []))
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
        try await engine.send(.runSlashCommand(target: .builtin(name: "/debug"), args: []))
        let sawUnsupported = await poll(timeout: .seconds(5)) {
            await sink.hasUnsupportedCommand(after: beforeDebug)
        }
        modeResults[.debug] = sawUnsupported ? .diagnosticOnly : .unsupported

        let firstTurn: TurnTiming
        do {
            firstTurn = try await Self.awaitFinalTurn(
                engine: engine,
                sink: sink,
                prompt: configuration.prompt,
                expectedSubstring: configuration.expectedFinalSubstring,
                timeout: configuration.assistantTextTimeout,
                version: version,
                modes: modeResults,
                turnLabel: "first"
            )
        } catch {
            await engine.shutdown(reason: .naturalExit)
            throw error
        }

        let secondTurn: TurnTiming
        do {
            secondTurn = try await Self.awaitFinalTurn(
                engine: engine,
                sink: sink,
                prompt: configuration.secondPrompt,
                expectedSubstring: configuration.expectedSecondFinalSubstring,
                timeout: configuration.assistantTextTimeout,
                version: version,
                modes: modeResults,
                turnLabel: "second"
            )
        } catch {
            await engine.shutdown(reason: .naturalExit)
            throw error
        }

        let events = await sink.snapshot()
        let sessionID = await sink.sessionID()
        await engine.shutdown(reason: .naturalExit)

        return Result(
            events: events,
            sessionID: sessionID,
            finalAssistantText: secondTurn.finalAssistantText,
            firstTurn: firstTurn,
            secondTurn: secondTurn,
            modeProbeResults: modeResults,
            cliVersion: version
        )
    }

    /// One prompt that should stream thoughts + a longer reply; measures chunk cadence.
    func runStreamingCadence(_ configuration: Configuration) async throws -> StreamingCadenceResult {
        let version = await Self.readVersion(executablePath: configuration.executablePath)
        let env = SystemEnvironment()
        let engine = AgentEngine(seams: .live)
        await engine.bootstrap()
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

        let streamPrompt = """
            Think briefly, then reply with exactly three short lines:
            1) stream-alpha
            2) stream-beta
            3) stream-gamma
            End with the token: codemixer-stream-ok
            """
        let before = await sink.eventCount()
        try await engine.send(.sendPrompt(text: streamPrompt, attachments: []))
        let sawFinal = await poll(timeout: configuration.assistantTextTimeout) {
            await sink.containsFinalAssistantText(matching: "codemixer-stream-ok", after: before)
        }
        let cadence = await sink.streamingCadence(after: before)
        let events = await sink.snapshot()
        let sessionID = await sink.sessionID()
        await engine.shutdown(reason: .naturalExit)

        guard sawFinal else {
            throw LiveCursorHarnessError.assistantTextTimedOut(
                events: events,
                sessionID: sessionID,
                version: version,
                modes: [:],
                turn: "streaming"
            )
        }

        return StreamingCadenceResult(
            sessionID: sessionID,
            cliVersion: version,
            thinkingChunkCount: cadence.thinkingChunkCount,
            nonFinalAssistantCount: cadence.nonFinalAssistantCount,
            distinctNonFinalLengths: cadence.distinctNonFinalLengths,
            assistantStreamSpan: cadence.assistantStreamSpan,
            thinkingStreamSpan: cadence.thinkingStreamSpan,
            finalAssistantText: cadence.finalAssistantText,
            events: events
        )
    }

    /// Seed a session with one turn, shut down, respawn, and `session/load` history.
    func runFreshProcessLoad(_ configuration: Configuration) async throws -> ResumeLoadResult {
        let version = await Self.readVersion(executablePath: configuration.executablePath)
        let seedPrompt = configuration.prompt
        let seedNeedle = configuration.expectedFinalSubstring

        let seedSessionID: String
        do {
            let seed = try await runSeedTurn(
                configuration: configuration,
                version: version,
                prompt: seedPrompt,
                expectedSubstring: seedNeedle
            )
            guard let id = seed.sessionID, !id.isEmpty else {
                throw LiveCursorHarnessError.sessionStartTimedOut(
                    events: seed.events,
                    version: version
                )
            }
            seedSessionID = id
        }

        // Fresh engine + adapter process — forces real `session/load` replay.
        let env = SystemEnvironment()
        let engine = AgentEngine(seams: .live)
        await engine.bootstrap()
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

        try await engine.start(
            adapter: adapter,
            workspace: configuration.workspace,
            resumeSessionID: seedSessionID
        )

        let ready = await poll(timeout: configuration.sessionReadyTimeout) {
            if await sink.hasAuthenticationError() { return true }
            if await sink.hasSessionLoadError() { return true }
            return await sink.hasNonEmptySession()
        }
        if await sink.hasAuthenticationError() {
            let events = await sink.snapshot()
            await engine.shutdown(reason: .naturalExit)
            throw LiveCursorHarnessError.authenticationRequired(events: events, version: version)
        }
        if await sink.hasSessionLoadError() {
            let events = await sink.snapshot()
            await engine.shutdown(reason: .naturalExit)
            throw LiveCursorHarnessError.historyLoadTimedOut(
                events: events,
                sessionID: seedSessionID,
                version: version,
                detail: "session/load error"
            )
        }
        guard ready else {
            let events = await sink.snapshot()
            await engine.shutdown(reason: .naturalExit)
            throw LiveCursorHarnessError.sessionStartTimedOut(events: events, version: version)
        }

        let historyReady = await poll(timeout: configuration.assistantTextTimeout) {
            let user = await sink.containsUserTurn(matching: seedPrompt)
            let assistant = await sink.containsFinalAssistantText(matching: seedNeedle)
            return user && assistant
        }
        let eventsAfterLoad = await sink.snapshot()
        let sawUser = await sink.containsUserTurn(matching: seedPrompt)
        let sawAssistant = await sink.containsFinalAssistantText(matching: seedNeedle)
        guard historyReady else {
            await engine.shutdown(reason: .naturalExit)
            throw LiveCursorHarnessError.historyLoadTimedOut(
                events: eventsAfterLoad,
                sessionID: seedSessionID,
                version: version,
                detail: "missing replayed user/assistant (user=\(sawUser), assistant=\(sawAssistant))"
            )
        }

        let followUp = try await Self.awaitFinalTurn(
            engine: engine,
            sink: sink,
            prompt: configuration.secondPrompt,
            expectedSubstring: configuration.expectedSecondFinalSubstring,
            timeout: configuration.assistantTextTimeout,
            version: version,
            modes: [:],
            turnLabel: "post-load"
        )
        let events = await sink.snapshot()
        await engine.shutdown(reason: .naturalExit)
        return ResumeLoadResult(
            priorSessionID: seedSessionID,
            reloadedEvents: events,
            sawPriorUserTurn: sawUser,
            sawPriorAssistantFinal: sawAssistant,
            followUpAssistantText: followUp.finalAssistantText,
            cliVersion: version
        )
    }

    private func runSeedTurn(
        configuration: Configuration,
        version: String?,
        prompt: String,
        expectedSubstring: String
    ) async throws -> (sessionID: String?, events: [AgentEvent]) {
        let env = SystemEnvironment()
        let engine = AgentEngine(seams: .live)
        await engine.bootstrap()
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
        _ = try await Self.awaitFinalTurn(
            engine: engine,
            sink: sink,
            prompt: prompt,
            expectedSubstring: expectedSubstring,
            timeout: configuration.assistantTextTimeout,
            version: version,
            modes: [:],
            turnLabel: "seed"
        )
        let sessionID = await sink.sessionID()
        let events = await sink.snapshot()
        await engine.shutdown(reason: .naturalExit)
        // Give the child a moment to exit before respawn.
        try? await Task.sleep(for: .milliseconds(500))
        return (sessionID, events)
    }

    /// Sends one prompt and waits for its final assistant text; returns wall time to final.
    private static func awaitFinalTurn(
        engine: AgentEngine,
        sink: LiveCursorEventSink,
        prompt: String,
        expectedSubstring: String,
        timeout: Duration,
        version: String?,
        modes: [ModeKind: ModeProbeResult],
        turnLabel: String
    ) async throws -> TurnTiming {
        let before = await sink.eventCount()
        let started = ContinuousClock.now
        try await engine.send(.sendPrompt(text: prompt, attachments: []))
        let sawText = await poll(timeout: timeout) {
            await sink.containsFinalAssistantText(matching: expectedSubstring, after: before)
        }
        let duration = ContinuousClock.now - started
        let events = await sink.snapshot()
        let sessionID = await sink.sessionID()
        guard sawText else {
            throw LiveCursorHarnessError.assistantTextTimedOut(
                events: events,
                sessionID: sessionID,
                version: version,
                modes: modes,
                turn: turnLabel
            )
        }
        let final = await sink.latestFinalAssistant(after: before)
        return TurnTiming(
            duration: duration,
            finalAssistantID: final?.id,
            finalAssistantText: final?.text
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
                               modes: [LiveCursorACPHarness.ModeKind: LiveCursorACPHarness.ModeProbeResult],
                               turn: String)
    case historyLoadTimedOut(events: [AgentEvent],
                             sessionID: String?,
                             version: String?,
                             detail: String)

    var description: String {
        switch self {
        case .authenticationRequired(let events, let version):
            return "Cursor ACP authentication required (version=\(version ?? "unknown"), events=\(events.count))"
        case .sessionStartTimedOut(let events, let version):
            return "timed out waiting for Cursor session (version=\(version ?? "unknown"), events=\(events.count))"
        case .assistantTextTimedOut(let events, let sessionID, let version, let modes, let turn):
            let modeSummary = modes.map { "\($0.key.rawValue)=\($0.value.rawValue)" }.sorted().joined(separator: ",")
            return "timed out waiting for \(turn) assistantText (session=\(sessionID ?? "nil"), version=\(version ?? "unknown"), modes=[\(modeSummary)], events=\(events.count))"
        case .historyLoadTimedOut(let events, let sessionID, let version, let detail):
            return "timed out waiting for session/load history (session=\(sessionID ?? "nil"), version=\(version ?? "unknown"), \(detail), events=\(events.count))"
        }
    }
}

private actor LiveCursorEventSink {
    private var events: [AgentEvent] = []
    private var timed: [(ContinuousClock.Instant, AgentEvent)] = []

    func ingest(_ stream: AsyncStream<MulticastEventBus.HistoryEntry>) async {
        for await entry in stream {
            timed.append((ContinuousClock.now, entry.event))
            events.append(entry.event)
            if events.count > 1024 { break }
        }
    }

    func snapshot() -> [AgentEvent] { events }
    func eventCount() -> Int { events.count }

    struct Cadence: Sendable {
        var thinkingChunkCount = 0
        var nonFinalAssistantCount = 0
        var distinctNonFinalLengths: [Int] = []
        var assistantStreamSpan: Duration?
        var thinkingStreamSpan: Duration?
        var finalAssistantText: String?
    }

    func streamingCadence(after index: Int) -> Cadence {
        var cadence = Cadence()
        var firstAssistant: ContinuousClock.Instant?
        var lastAssistant: ContinuousClock.Instant?
        var firstThought: ContinuousClock.Instant?
        var lastThought: ContinuousClock.Instant?
        var lastLength = 0
        for (at, event) in timed.dropFirst(index) {
            switch event {
            case .thinkingChunk:
                cadence.thinkingChunkCount += 1
                if firstThought == nil { firstThought = at }
                lastThought = at
            case .assistantText(_, _, let text, let isFinal):
                if isFinal {
                    cadence.finalAssistantText = text
                } else {
                    cadence.nonFinalAssistantCount += 1
                    if text.count != lastLength {
                        cadence.distinctNonFinalLengths.append(text.count)
                        lastLength = text.count
                    }
                    if firstAssistant == nil { firstAssistant = at }
                    lastAssistant = at
                }
            default:
                break
            }
        }
        if let firstAssistant, let lastAssistant, firstAssistant != lastAssistant {
            cadence.assistantStreamSpan = lastAssistant - firstAssistant
        }
        if let firstThought, let lastThought, firstThought != lastThought {
            cadence.thinkingStreamSpan = lastThought - firstThought
        }
        return cadence
    }

    func hasNonEmptySession() -> Bool {
        events.contains {
            if case .sessionStarted(let id, _, _) = $0 { return !id.isEmpty }
            return false
        }
    }

    func hasAuthenticationError() -> Bool {
        events.contains { if case .error(.authenticationRequired) = $0 { return true }; return false }
    }

    func hasSessionLoadError() -> Bool {
        events.contains {
            if case .error(.unsupportedOperation(let detail)) = $0 {
                return detail.contains("session-load-failed") || detail.contains("resume-unsupported")
            }
            return false
        }
    }

    func containsUserTurn(matching substring: String) -> Bool {
        events.contains {
            if case .userTurn(_, let text) = $0 {
                return text.localizedCaseInsensitiveContains(substring)
            }
            return false
        }
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

    func containsFinalAssistantText(matching substring: String, after index: Int = 0) -> Bool {
        events.dropFirst(index).contains {
            if case .assistantText(_, _, let text, true) = $0 {
                return text.localizedCaseInsensitiveContains(substring)
            }
            return false
        }
    }

    func latestFinalAssistant(after index: Int = 0) -> (id: String, text: String)? {
        for event in events.dropFirst(index).reversed() {
            if case .assistantText(let id, _, let text, true) = event {
                return (id, text)
            }
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
