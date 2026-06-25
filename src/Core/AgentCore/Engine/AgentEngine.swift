import Foundation
import OSLog
import AgentProtocol

/// The agent-agnostic orchestrator.
///
/// Lifecycle:
///
///   `init` → `start(adapter:workspace:resumeSessionID:)` → events flow on
///   the `MulticastEventBus` → callers issue `AgentCommand`s through the
///   `AgentEngineCommandPort` conformance → eventually `shutdown()`.
///
/// The engine is a plain `actor` (not `@MainActor`) so the same binary runs
/// inside the GUI app and the headless daemon.
public actor AgentEngine: AgentEngineCommandPort {

    public enum EngineState: Sendable, Equatable {
        case stopped
        case starting
        case running(sessionID: String?)
        case stopping
    }

    let log = Logger(subsystem: AppIdentity.logSubsystem, category: "Engine")
    let seams: Seams
    private let ptyFactory: AgentPTYFactory

    /// Bus that fans out `AgentEvent` to N subscribers (Mac UI + remote
    /// clients). Exposed so the UI and remote-control server can subscribe
    /// without going through the actor.
    public nonisolated let bus: MulticastEventBus

    var adapter: (any AgentAdapter)?
    private var state: EngineState = .stopped
    var pty: (any AgentPTY)?
    private var terminal: TerminalEngine?
    var hookServer: HookServer?
    private var sessionIDContinuation: AsyncStream<String>.Continuation?
    var currentSessionID: String?
    var currentTurnID: UUID?
    var pendingPermissions: [UUID: PermissionPrompt] = [:]
    var lastUserBubbleID: UUID?
    var heartbeat: HeartbeatActivityMonitor?
    private var phraseResolver: StatusPhraseResolver
    private var eventForwardingTask: Task<Void, Never>?
    var workspace: URL?
    var transcript: [SnapshotService.SnapshotMessage] = []
    var changedFiles: [String] = []
    var permissionTimeouts: [UUID: Task<Void, Never>] = [:]
    private var resumeStartupWatchdogTask: Task<Void, Never>?
    private var resumeStartupWatchdogTurnID: UUID?
    private var resumePromptReadyTask: Task<Void, Never>?
    private var resumePromptReadySampleCount = 0
    private var resumeStartupSessionID: String?
    private var resumeStartupWaiters: [CheckedContinuation<Void, Never>] = []
    var startupSubmitRecoveryArmed = false
    private var startupSubmitRecoveryTask: Task<Void, Never>?

    private static let resumePromptReadyRequiredSamples = 2

    /// Permissions that go unresolved for longer than this are auto-denied so
    /// a headless session never deadlocks waiting for human input. Injected at
    /// init time so tests can drive timeouts with `FakeClock`.
    private let permissionTimeout: Duration

    /// Default auto-deny window for unresolved permission prompts.
    public static let defaultPermissionTimeout: Duration = .seconds(300)

    /// User preferences (appearance + auto-approval rules) — public so the
    /// UI and remote-control server can subscribe to mutations.
    public nonisolated let prefs: PrefsStore

    /// Per-machine recent-projects cache.
    public nonisolated let sessions: SessionStore

    nonisolated let snapshots: SnapshotService
    nonisolated let attachmentResolver: AttachmentResolver
    nonisolated let gitReverter: GitReverter

    public init(seams: Seams = .live,
                permissionTimeout: Duration = AgentEngine.defaultPermissionTimeout) {
        self.init(seams: seams,
                  permissionTimeout: permissionTimeout,
                  ptyFactory: Self.livePTY)
    }

    init(seams: Seams = .live,
         permissionTimeout: Duration = AgentEngine.defaultPermissionTimeout,
         ptyFactory: @escaping AgentPTYFactory) {
        self.seams = seams
        self.permissionTimeout = permissionTimeout
        self.ptyFactory = ptyFactory
        self.bus = MulticastEventBus(random: seams.random)
        self.phraseResolver = StatusPhraseResolver()
        let p = PrefsStore(environment: seams.environment, fileSystem: seams.fileSystem)
        let s = SessionStore(environment: seams.environment, fileSystem: seams.fileSystem)
        self.prefs = p
        self.sessions = s
        self.snapshots = SnapshotService(prefs: p,
                                         sessions: s,
                                         fileSystem: seams.fileSystem)
        self.attachmentResolver = AttachmentResolver(environment: seams.environment,
                                                     fileSystem: seams.fileSystem)
        self.gitReverter = GitReverter()
    }

    private static func livePTY(_ spec: PTYHost.ChildSpec) throws -> any AgentPTY {
        try PTYHost(spec: spec)
    }

    /// Boot the stores (no-op if their JSON doesn't exist yet).
    public func bootstrap() async {
        await prefs.load()
        await sessions.load()
    }

    /// Snapshot of the current engine state. Used by the daemon's idle-exit monitor.
    public var currentState: EngineState { state }

    /// Read-only terminal screen snapshot for the debug terminal sheet.
    /// Returns an empty string before a PTY-backed session has started.
    public func terminalSnapshotText() async -> String {
        await terminal?.snapshotText() ?? ""
    }

    // MARK: - Lifecycle

    /// Start a session with `adapter` against `workspace`.
    ///
    /// Resolves the user's shell environment, optionally starts a hook server
    /// (if the adapter declares `.hooksOverUDS`), spawns the agent under a
    /// fresh PTY, and bridges the adapter's event stream onto the bus.
    public func start(adapter: any AgentAdapter,
                      workspace: URL,
                      resumeSessionID: String? = nil,
                      permissionMode: PermissionMode = .default) async throws {
        guard state == .stopped else { throw AgentError.internalInvariant(detail: "engine not idle") }
        state = .starting
        self.adapter = adapter
        self.workspace = workspace
        self.transcript = []
        self.changedFiles = []
        resumeStartupSessionID = adapter.capabilities.contains(.ptyTUIFallback)
            ? (resumeSessionID ?? "")
            : nil
        startupSubmitRecoveryArmed = resumeStartupSessionID != nil
        resumePromptReadySampleCount = 0
        resumeStartupWaiters.removeAll()

        try? await sessions.recordOpen(path: workspace.path,
                                       displayName: workspace.lastPathComponent,
                                       clock: seams.clock,
                                       sessionID: resumeSessionID)

        let resolvedEnv = await ShellEnvironmentResolver(environment: seams.environment).resolve()

        // Optional hook server.
        var hookSocketPath: String?
        var hookHandle: HookSocketHandle?
        if adapter.capabilities.contains(.hooksOverUDS) {
            let server = try HookServer(environment: seams.environment,
                                        fileSystem: seams.fileSystem,
                                        random: seams.random)
            try await server.start()
            hookSocketPath = server.socketPath
            hookHandle = await server.makeHandle()
            self.hookServer = server

            if let path = hookSocketPath {
                try await adapter.installHookConfiguration(socketPath: path,
                                                           workspace: workspace,
                                                           fileSystem: seams.fileSystem)
            }
        }

        // Build launch context and resolve the binary.
        let binary: URL
        do {
            binary = try await adapter.locateBinary(env: resolvedEnv)
        } catch {
            state = .stopped
            throw AgentError.binaryNotFound(agentID: adapter.id,
                                            hint: error.localizedDescription)
        }

        let context = LaunchContext(workspace: workspace,
                                    hookSocketPath: hookSocketPath,
                                    resumeSessionID: resumeSessionID,
                                    permissionMode: permissionMode,
                                    extraEnv: adapter.defaultEnvOverrides())
        let argv = adapter.buildLaunchArgv(context: context)
        let env = resolvedEnv.withOverrides(adapter.defaultEnvOverrides())

        // Spawn the PTY + terminal engine.
        let terminal = TerminalEngine()
        self.terminal = terminal

        let spec = PTYHost.ChildSpec(executable: binary,
                                     arguments: Array(argv.dropFirst()),
                                     environment: env,
                                     workingDirectory: workspace)
        let pty: any AgentPTY
        do {
            pty = try ptyFactory(spec)
        } catch {
            state = .stopped
            throw AgentError.spawnFailed(errno: Self.errno(from: error),
                                         detail: String(describing: error))
        }
        self.pty = pty

        // Stream bytes from the PTY into the terminal engine while also
        // forwarding them downstream to the adapter.
        var ptyFanoutContinuation: AsyncStream<Data>.Continuation!
        let ptyFanout = AsyncStream<Data>(bufferingPolicy: .bufferingOldest(StreamBufferDefaults.ptyChunks)) { c in ptyFanoutContinuation = c }

        let outbound = pty.outboundBytes
        Task { [weak self] in
            for await chunk in outbound {
                await self?.terminal?.feed(chunk)
                ptyFanoutContinuation.yield(chunk)
            }
            ptyFanoutContinuation.finish()
        }

        // Session-id discovery is hot — empty until the adapter learns it.
        var sessionIDContinuation: AsyncStream<String>.Continuation!
        let sessionIDStream = AsyncStream<String> { c in sessionIDContinuation = c }
        self.sessionIDContinuation = sessionIDContinuation
        if let resumeSessionID {
            currentSessionID = resumeSessionID
            sessionIDContinuation.yield(resumeSessionID)
        }

        let inputs = AgentInputs(ptyOutput: ptyFanout,
                                 screen: terminal,
                                 hookSocket: hookHandle,
                                 workspace: workspace,
                                 resumeSessionID: resumeSessionID,
                                 sessionID: sessionIDStream)

        let adapterStream = adapter.makeEventStream(inputs: inputs)

        // Heartbeat activity monitor — server-side, drives `noEventGap`.
        let monitor = HeartbeatActivityMonitor(clock: seams.clock) { [weak self] tick in
            await self?.onHeartbeat(tick)
        }
        self.heartbeat = monitor

        state = .running(sessionID: resumeSessionID)
        log.notice("engine started workspace=\(workspace.path, privacy: .public)")
        await bus.publish(.sessionStarted(sessionID: resumeSessionID ?? "",
                                          model: nil,
                                          cwd: workspace))

        // Forward adapter events onto the bus, with bookkeeping side-effects.
        eventForwardingTask = Task { [weak self] in
            for await event in adapterStream {
                await self?.ingest(event)
            }
        }

        if let startupGateID = resumeStartupSessionID {
            startResumePromptReadyWait(sessionID: startupGateID)
            startResumeStartupWatchdog(sessionID: startupGateID)
        }
    }

    /// Shut everything down: cancel the read pipeline, kill the child, close
    /// the hook server and FS watcher, drain the bus. Idempotent.
    public func shutdown(reason: AgentProtocol.StopReason = .userCancel) async {
        guard state != .stopped else { return }
        state = .stopping

        eventForwardingTask?.cancel()
        eventForwardingTask = nil
        cancelResumeStartupWatchdog()
        cancelResumePromptReadyWait()
        startupSubmitRecoveryTask?.cancel()
        startupSubmitRecoveryTask = nil
        startupSubmitRecoveryArmed = false
        finishResumeStartupGate()
        await pty?.close()
        pty = nil
        await hookServer?.stop()
        hookServer = nil
        sessionIDContinuation?.finish()
        sessionIDContinuation = nil
        await heartbeat?.endTurn()
        heartbeat = nil
        terminal = nil
        adapter = nil
        currentSessionID = nil
        currentTurnID = nil
        pendingPermissions.removeAll()
        lastUserBubbleID = nil
        for task in permissionTimeouts.values { task.cancel() }
        permissionTimeouts.removeAll()
        await phraseResolver.reset()

        await bus.publish(.stopped(reason: reason))
        state = .stopped
        log.notice("engine stopped reason=\(String(describing: reason), privacy: .public)")
    }

    // MARK: - Internal — adapter event ingestion

    private func ingest(_ event: AgentEvent) async {
        var publishIdleAfterEvent = false
        // Update bookkeeping before broadcasting.
        switch event {
        case .sessionStarted(let id, _, _):
            if resumeStartupSessionID != nil {
                if resumeStartupSessionID?.isEmpty == true {
                    resumeStartupSessionID = id
                    startResumePromptReadyWait(sessionID: id)
                    startResumeStartupWatchdog(sessionID: id)
                }
                if resumePromptReadyTask == nil {
                    startResumePromptReadyWait(sessionID: id)
                }
            } else {
                cancelResumeStartupWatchdog()
            }
            if currentSessionID == id {
                return
            }
            currentSessionID = id
            sessionIDContinuation?.yield(id)
            state = .running(sessionID: id)
        case .permissionRequest(let prompt):
            pendingPermissions[prompt.id] = prompt
            startPermissionTimeout(for: prompt.id)
        case .stopped:
            // Adapter signalled the agent exited — let `shutdown` finish up.
            Task { [weak self] in await self?.shutdown(reason: .naturalExit) }
        case .toolEnd:
            await heartbeat?.bump(baseline: .awaitingFirstChunk)
        case .assistantText:
            if case .assistantText(let id, _, _, let isFinal) = event {
                log.debug("ingested assistantText id=\(id, privacy: .public) final=\(isFinal, privacy: .public)")
                if isFinal {
                    await heartbeat?.endTurn()
                    currentTurnID = nil
                    publishIdleAfterEvent = true
                } else {
                    await heartbeat?.bump(baseline: .awaitingFirstChunk)
                }
            }
        case .activityStateChanged(.idle):
            await heartbeat?.endTurn()
            currentTurnID = nil
        case .textDelta:
            await heartbeat?.bump(baseline: .streamingText)
        case .toolStart:
            await heartbeat?.bump(baseline: .runningTool)
        case .thinkingChunk:
            await heartbeat?.bump(baseline: .thinking)
        case .statusPhraseChanged(let source, let phrase):
            if let (winnerSource, winnerPhrase) = await phraseResolver.update(source, phrase: phrase) {
                await record(event)
                await bus.publish(.statusPhraseChanged(source: winnerSource, phrase: winnerPhrase))
            }
            return
        default:
            break
        }
        await record(event)
        await bus.publish(event)
        if publishIdleAfterEvent {
            await bus.publish(.activityStateChanged(.idle))
        }
    }

    private func record(_ event: AgentEvent) async {
        switch event {
        case .userTurn(_, let text):
            transcript.append(.init(role: "user", text: text, timestamp: seams.clock.now()))
        case .assistantText(_, _, let text, let isFinal) where isFinal:
            transcript.append(.init(role: "assistant", text: text, timestamp: seams.clock.now()))
        case .fileTouched(let url, _):
            let path = url.path
            if !changedFiles.contains(path) { changedFiles.append(path) }
        default:
            break
        }
    }

    private func onHeartbeat(_ tick: HeartbeatActivityMonitor.Tick) async {
        guard let turn = currentTurnID else { return }
        await bus.publish(.noEventGap(turnID: turn, elapsed: tick.elapsed))
        await bus.publish(.activityStateChanged(tick.substate))
    }

    private func startResumeStartupWatchdog(sessionID: String) {
        cancelResumeStartupWatchdog()
        let turnID = seams.random.uuid()
        resumeStartupWatchdogTurnID = turnID
        resumeStartupWatchdogTask = Task { [weak self, clock = seams.clock] in
            do {
                try await clock.sleep(for: ActivityTiming.resumeStartupStallTimeout)
            } catch {
                return
            }
            await self?.markResumeStartupStalled(sessionID: sessionID, turnID: turnID)
        }
    }

    private func cancelResumeStartupWatchdog() {
        resumeStartupWatchdogTask?.cancel()
        resumeStartupWatchdogTask = nil
        resumeStartupWatchdogTurnID = nil
    }

    private func markResumeStartupStalled(sessionID: String, turnID: UUID) async {
        guard resumeStartupSessionID == sessionID,
              resumeStartupWatchdogTurnID == turnID else { return }
        resumeStartupWatchdogTask = nil
        resumeStartupWatchdogTurnID = nil
        guard pendingPermissions.isEmpty else { return }
        cancelResumePromptReadyWait()
        log.warning("resume startup stalled session=\(sessionID, privacy: .public)")
        await bus.publish(.activityStateChanged(.probablyStuck))
        await bus.publish(.noEventGap(turnID: turnID,
                                      elapsed: ActivityTiming.probablyStuckThreshold + .seconds(1)))
        finishResumeStartupGate()
    }

    private func startResumePromptReadyWait(sessionID: String) {
        cancelResumePromptReadyWait()
        resumePromptReadySampleCount = 0
        resumePromptReadyTask = Task { [weak self, clock = seams.clock] in
            while !Task.isCancelled {
                if await self?.hasStableResumePromptReadySample(sessionID: sessionID) == true {
                    await self?.markResumePromptReady(sessionID: sessionID)
                    return
                }
                do {
                    try await clock.sleep(for: ActivityTiming.resumePromptReadyPollInterval)
                } catch {
                    return
                }
            }
        }
    }

    private func cancelResumePromptReadyWait() {
        resumePromptReadyTask?.cancel()
        resumePromptReadyTask = nil
        resumePromptReadySampleCount = 0
    }

    private func hasStableResumePromptReadySample(sessionID: String) async -> Bool {
        guard resumeStartupSessionID == sessionID,
              let terminal else { return false }
        if Self.rowsContainClaudeReadyPrompt(await terminal.snapshotRows()) {
            resumePromptReadySampleCount += 1
        } else {
            resumePromptReadySampleCount = 0
        }
        return resumePromptReadySampleCount >= Self.resumePromptReadyRequiredSamples
    }

    private func markResumePromptReady(sessionID: String) {
        guard resumeStartupSessionID == sessionID else { return }
        resumePromptReadyTask = nil
        cancelResumeStartupWatchdog()
        log.debug("resume prompt ready session=\(sessionID, privacy: .public)")
        finishResumeStartupGate()
    }

    func scheduleStartupSubmitRecovery(turnID: UUID) {
        startupSubmitRecoveryTask?.cancel()
        startupSubmitRecoveryTask = Task { [weak self, clock = seams.clock] in
            do {
                try await clock.sleep(for: ActivityTiming.startupSubmitRecoveryDelay)
            } catch {
                return
            }
            await self?.recoverStartupSubmitIfNeeded(turnID: turnID)
        }
    }

    private func recoverStartupSubmitIfNeeded(turnID: UUID) async {
        startupSubmitRecoveryTask = nil
        // The turn already progressed (response arrived / went idle) — nothing to do.
        guard currentTurnID == turnID else { return }
        // Never inject Enter while a trust/permission screen is awaiting the user.
        guard pendingPermissions.isEmpty else { return }
        guard let terminal,
              Self.rowsShowUnsubmittedPrompt(await terminal.snapshotRows()) else { return }
        log.warning("startup submit recovery: re-sending Enter turn=\(turnID, privacy: .public)")
        try? await pty?.write(Data("\r".utf8))
    }

    static func rowsContainClaudeReadyPrompt(_ rows: [String]) -> Bool {
        let normalizedRows = rows.map(normalizedTerminalRow(_:))
        let hasShortcutFooter = normalizedRows.contains { $0.contains("for shortcuts") }
        return normalizedRows.contains { row in
            row == "❯" || (hasShortcutFooter && row == ">")
        }
    }

    /// True when an input row still carries unsubmitted text (`❯ <text>`),
    /// meaning Claude has not accepted the prompt yet. The complement of
    /// `rowsContainClaudeReadyPrompt`, which matches the *empty* input row.
    static func rowsShowUnsubmittedPrompt(_ rows: [String]) -> Bool {
        let normalizedRows = rows.map(normalizedTerminalRow(_:))
        let hasShortcutFooter = normalizedRows.contains { $0.contains("for shortcuts") }
        return normalizedRows.contains { row in
            let isPromptRow = row.hasPrefix("❯") || (hasShortcutFooter && row.hasPrefix(">"))
            guard isPromptRow else { return false }
            let rest = row.drop { $0 == "❯" || $0 == ">" }
                .trimmingCharacters(in: .whitespaces)
            return !rest.isEmpty
        }
    }

    private static func normalizedTerminalRow(_ row: String) -> String {
        // SwiftTerm back-fills unwritten cells with NUL when output advances rows
        // without a carriage return; strip those before trimming so prompt
        // detection sees the visible glyphs only.
        row
            .replacingOccurrences(of: "\u{0000}", with: "")
            .replacingOccurrences(of: "\u{00A0}", with: " ")
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    func waitForResumeStartupIfNeeded() async {
        guard resumeStartupSessionID != nil else { return }
        await withCheckedContinuation { continuation in
            if resumeStartupSessionID == nil {
                continuation.resume()
            } else {
                resumeStartupWaiters.append(continuation)
            }
        }
    }

    private func finishResumeStartupGate() {
        resumeStartupSessionID = nil
        let waiters = resumeStartupWaiters
        resumeStartupWaiters.removeAll()
        waiters.forEach { $0.resume() }
    }

    // MARK: - Permission timeout

    private func startPermissionTimeout(for id: UUID) {
        let clock = seams.clock
        let duration = permissionTimeout
        permissionTimeouts[id] = Task {
            try? await clock.sleep(for: duration)
            guard !Task.isCancelled else { return }
            await self.handlePermissionTimeout(id)
        }
    }

    private func handlePermissionTimeout(_ id: UUID) async {
        guard let prompt = pendingPermissions.removeValue(forKey: id) else { return }
        permissionTimeouts.removeValue(forKey: id)?.cancel()
        log.notice("permission timeout for \(id, privacy: .public) — auto-denying")

        try? await deliverPermissionResponse(.deny, for: prompt, id: id)
        await bus.publish(.permissionAlreadyResolved(id: id, byDevice: "timeout"))
        let totalSeconds = Int(Double(permissionTimeout.components.seconds))
        await bus.publish(.error(.unsupportedOperation(
            detail: "Permission request timed out after \(max(1, totalSeconds / 60)) minutes — auto-denied."
        )))
    }

    func deliverPermissionResponse(_ decision: PermissionDecision,
                                   for prompt: PermissionPrompt,
                                   id: UUID) async throws {
        guard let adapter else { return }
        switch adapter.encodePermissionResponse(decision, for: prompt) {
        case .writePTY(let data):
            try await pty?.write(data)
        case .respondToHookProcess(let json):
            await hookServer?.respond(to: id, with: json)
        case .both(let ptyBytes, let hookOut):
            try await pty?.write(ptyBytes)
            await hookServer?.respond(to: id, with: hookOut)
        }
    }

    private static func errno(from error: any Error) -> Int32 {
        switch error as? PTYError {
        case .spawnFailed(let e, _): return e
        case .openptyFailed(let e): return e
        case .setWinsizeFailed(let e): return e
        case .writeFailed(let e): return e
        case .alreadyClosed, nil: return -1
        }
    }

}
