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
    private let transportFactory: AgentTransportFactory

    /// Bus that fans out `AgentEvent` to N subscribers (Mac UI + remote
    /// clients). Exposed so the UI and remote-control server can subscribe
    /// without going through the actor.
    public nonisolated let bus: MulticastEventBus

    var adapter: (any AgentAdapter)?
    var state: EngineState = .stopped
    var transport: (any AgentTransport)?
    private var terminal: (any TerminalSnapshotting)?
    var hookServer: HookServer?
    private var sessionIDContinuation: AsyncStream<String>.Continuation?
    var currentSessionID: String?
    var currentTurnID: UUID?
    var pendingPermissions: [UUID: PermissionPrompt] = [:]
    var lastUserBubbleID: UUID?
    var heartbeat: HeartbeatActivityMonitor?
    private var phraseResolver: StatusPhraseResolver
    private var eventForwardingTask: Task<Void, Never>?
    private var bellTask: Task<Void, Never>?
    private var shutdownInFlight = false
    var workspace: URL?
    var transcript: [SnapshotService.SnapshotMessage] = []
    var changedFiles: [String] = []
    var permissionTimeouts: [UUID: Task<Void, Never>] = [:]
    private var resumeStartupWatchdogTask: Task<Void, Never>?
    private var resumeStartupWatchdogTurnID: UUID?
    private var resumePromptReadyTask: Task<Void, Never>?
    private var resumePromptReadySampleCount = 0
    private var resumePromptReadyEarliest: ContinuousClock.Instant?
    private var resumeStartupSessionID: String?
    private var resumeStartupWaiters: [CheckedContinuation<Void, Never>] = []
    /// True when `start` was called with a concrete `--resume` id. Those
    /// sessions must not arm the ready-prompt gate until hook SessionStart.
    private var resumeStartupRequiresHookSession = false
    var startupSubmitRecoveryArmed = false
    private var startupSubmitRecoveryTask: Task<Void, Never>?
    private var startupSubmitRecoveryBytes: Data?
    private var startupSubmitRecoveryAttempt = 0
    /// Set when `sendPrompt` starts a turn; cleared only by a matching live
    /// `UserPromptSubmit` (or shutdown). While set, historical transcript
    /// replay must not end the turn or cancel submit recovery.
    var currentTurnAwaitingAcceptance = false
    var currentTurnPromptText: String?
    private var fsWatcher: FSEventsWatcher?
    private var fsWatcherTask: Task<Void, Never>?
    private var diffRefreshTask: Task<Void, Never>?

    private static let resumePromptReadyRequiredSamples = 2
    private static let diffRefreshCoalesce: Duration = .milliseconds(50)

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
                  transportFactory: LiveAgentTransportFactory.make)
    }

    init(seams: Seams = .live,
         permissionTimeout: Duration = AgentEngine.defaultPermissionTimeout,
         transportFactory: @escaping AgentTransportFactory) {
        self.seams = seams
        self.permissionTimeout = permissionTimeout
        self.transportFactory = transportFactory
        self.bus = MulticastEventBus(random: seams.random)
        self.phraseResolver = StatusPhraseResolver()
        let p = PrefsStore(environment: seams.environment, fileSystem: seams.fileSystem)
        let s = SessionStore(environment: seams.environment, fileSystem: seams.fileSystem)
        self.prefs = p
        self.sessions = s
        self.snapshots = SnapshotService(prefs: p, sessions: s)
        self.attachmentResolver = AttachmentResolver(environment: seams.environment,
                                                     fileSystem: seams.fileSystem)
        self.gitReverter = GitReverter()
    }

    /// Boot the stores (no-op if their JSON doesn't exist yet).
    public func bootstrap() async {
        await prefs.load()
        await sessions.load()
    }

    /// Snapshot of the current engine state. Used by the daemon's idle-exit monitor.
    public var currentState: EngineState { state }

    /// Read-only terminal screen snapshot for the debug terminal sheet.
    /// Returns an empty string before an interactive-terminal session has started.
    public func terminalSnapshotText() async -> String {
        await terminal?.snapshotText() ?? ""
    }

    // MARK: - Lifecycle

    /// Start a session with `adapter` against `workspace`.
    ///
    /// Resolves the user's shell environment, optionally starts a hook server
    /// (if the adapter declares `.hooksOverUDS`), binds an `AgentTransport`
    /// matching the adapter's descriptor, and bridges the adapter's event
    /// stream onto the bus.
    public func start(adapter: any AgentAdapter,
                      workspace: URL,
                      resumeSessionID: String? = nil,
                      permissionMode: PermissionMode = .default) async throws {
        guard state == .stopped else { throw AgentError.internalInvariant(detail: "engine not idle") }
        state = .starting
        self.adapter = adapter
        // Always standardize so UI cwd filtering matches ACP `sessionStarted`.
        let workspace = workspace.standardizedFileURL
        self.workspace = workspace
        self.transcript = []
        self.changedFiles = []
        let usesTerminal = adapter.transportDescriptor.requiresTerminalEmulation
            && adapter.capabilities.contains(.ptyTUIFallback)
        let handshakeGate = adapter.capabilities.contains(.sessionHandshakeGate)
        resumeStartupSessionID = usesTerminal ? (resumeSessionID ?? "") : nil
        resumeStartupRequiresHookSession = usesTerminal && resumeSessionID != nil
        startupSubmitRecoveryArmed = resumeStartupSessionID != nil
        resumePromptReadySampleCount = 0
        resumePromptReadyEarliest = nil
        resumeStartupWaiters.removeAll()

        do {
            try await sessions.recordOpen(path: workspace.path,
                                          displayName: workspace.lastPathComponent,
                                          clock: seams.clock,
                                          sessionID: resumeSessionID)
        } catch {
            await SilentDiagnostics.shared.record(kind: .other,
                                                  owner: "AgentEngine",
                                                  summary: "sessions.recordOpen failed during start",
                                                  details: String(describing: error))
        }

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
            await rollbackPartialStart()
            throw AgentError.binaryNotFound(agentID: adapter.id,
                                            hint: error.localizedDescription)
        }

        let context = LaunchContext(workspace: workspace,
                                    hookSocketPath: hookSocketPath,
                                    resumeSessionID: resumeSessionID,
                                    permissionMode: permissionMode,
                                    extraEnv: adapter.defaultEnvOverrides())
        let argv = adapter.buildLaunchArgv(context: context)
        var env = resolvedEnv.ptySpawnEnvironment(adapterOverrides: adapter.defaultEnvOverrides())
        env["PWD"] = workspace.path

        let launch = AgentTransportLaunchSpec(
            executable: binary,
            arguments: Array(argv.dropFirst()),
            environment: env,
            workingDirectory: workspace
        )
        let transport: any AgentTransport
        do {
            transport = try transportFactory(adapter.transportDescriptor, launch)
        } catch {
            await rollbackPartialStart()
            throw AgentError.spawnFailed(errno: Self.errno(from: error),
                                         detail: String(describing: error))
        }
        self.transport = transport
        self.terminal = transport.terminalSnapshot

        // Session-id discovery is hot — empty until the adapter learns it.
        var sessionIDContinuation: AsyncStream<String>.Continuation!
        let sessionIDStream = AsyncStream<String> { c in sessionIDContinuation = c }
        self.sessionIDContinuation = sessionIDContinuation
        if let resumeSessionID {
            currentSessionID = resumeSessionID
            sessionIDContinuation.yield(resumeSessionID)
        }

        let inputs = AgentInputs(outputBytes: transport.outboundBytes,
                                 writeBytes: { bytes in
                                     try await transport.write(bytes)
                                 },
                                 terminal: transport.terminalSnapshot,
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
        // Handshake-gated adapters (Cursor / ACP) publish the real SessionStart
        // after protocol open. Emitting the resume id here would unlock the
        // composer before `session/load` / `session/new` completes.
        let bootstrapSessionID = handshakeGate ? "" : (resumeSessionID ?? "")
        await bus.publish(.sessionStarted(sessionID: bootstrapSessionID,
                                          model: nil,
                                          cwd: workspace))

        // Forward adapter events onto the bus, with bookkeeping side-effects.
        eventForwardingTask = Task { [weak self] in
            for await event in adapterStream {
                await self?.ingest(event)
            }
        }

        // Bell fan-out — empty stream for non-terminal transports finishes immediately.
        let bells = transport.bellEvents
        bellTask = Task { [weak self] in
            for await _ in bells {
                await self?.bus.publish(.bell)
            }
        }

        let bootstrap = adapter.sessionBootstrapBytes(context: context)
        if !bootstrap.isEmpty {
            do {
                try await transport.write(bootstrap)
            } catch {
                await rollbackPartialStart()
                throw AgentError.spawnFailed(errno: Self.errno(from: error),
                                             detail: "bootstrap write failed: \(error)")
            }
        }

        if let startupGateID = resumeStartupSessionID {
            if resumeStartupRequiresHookSession {
                // Hold writes, but do not scrape the TUI yet — resume paints
                // history first and a premature ready match swallows prompts.
                startResumeStartupWatchdog(
                    sessionID: startupGateID,
                    timeout: ActivityTiming.resumedSessionStartupStallTimeout
                )
            } else {
                startResumePromptReadyWait(sessionID: startupGateID)
                startResumeStartupWatchdog(sessionID: startupGateID)
            }
        }

        await startFSWatcher(workspace: workspace)
    }

    /// Shut everything down: cancel the read pipeline, kill the child, close
    /// the hook server and FS watcher, drain the bus. Idempotent.
    public func shutdown(reason: AgentProtocol.StopReason = .userCancel) async {
        guard state != .stopped else { return }
        state = .stopping

        eventForwardingTask?.cancel()
        eventForwardingTask = nil
        bellTask?.cancel()
        bellTask = nil
        await stopFSWatcher()
        cancelResumeStartupWatchdog()
        cancelResumePromptReadyWait()
        startupSubmitRecoveryTask?.cancel()
        startupSubmitRecoveryTask = nil
        startupSubmitRecoveryArmed = false
        startupSubmitRecoveryBytes = nil
        resumeStartupRequiresHookSession = false
        resumePromptReadyEarliest = nil
        finishResumeStartupGate()
        await transport?.close()
        transport = nil
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
        currentTurnAwaitingAcceptance = false
        currentTurnPromptText = nil
        for task in permissionTimeouts.values { task.cancel() }
        permissionTimeouts.removeAll()
        await phraseResolver.reset()

        await bus.publish(.stopped(reason: reason))
        state = .stopped
        shutdownInFlight = false
        log.notice("engine stopped reason=\(String(describing: reason), privacy: .public)")
    }

    /// Tear down a partially started session without publishing `.stopped`.
    private func rollbackPartialStart() async {
        eventForwardingTask?.cancel()
        eventForwardingTask = nil
        bellTask?.cancel()
        bellTask = nil
        await stopFSWatcher()
        cancelResumeStartupWatchdog()
        cancelResumePromptReadyWait()
        startupSubmitRecoveryTask?.cancel()
        startupSubmitRecoveryTask = nil
        startupSubmitRecoveryArmed = false
        startupSubmitRecoveryBytes = nil
        resumeStartupRequiresHookSession = false
        resumePromptReadyEarliest = nil
        finishResumeStartupGate()
        await transport?.close()
        transport = nil
        await hookServer?.stop()
        hookServer = nil
        sessionIDContinuation?.finish()
        sessionIDContinuation = nil
        await heartbeat?.endTurn()
        heartbeat = nil
        terminal = nil
        adapter = nil
        workspace = nil
        currentSessionID = nil
        currentTurnID = nil
        pendingPermissions.removeAll()
        lastUserBubbleID = nil
        currentTurnAwaitingAcceptance = false
        currentTurnPromptText = nil
        for task in permissionTimeouts.values { task.cancel() }
        permissionTimeouts.removeAll()
        transcript = []
        changedFiles = []
        await phraseResolver.reset()
        state = .stopped
        await SilentDiagnostics.shared.record(kind: .enginePartialStartRollback,
                                              owner: "AgentEngine",
                                              summary: "Rolled back partial engine start")
    }

    /// Serialize adapter-driven shutdown so nested ingest/shutdown races cannot
    /// double-stop or cancel the forwarding task mid-flight.
    private func requestShutdown(reason: StopReason) {
        guard !shutdownInFlight else { return }
        shutdownInFlight = true
        Task { [weak self] in
            await self?.shutdown(reason: reason)
        }
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
                    armResumeStartupGate(sessionID: id)
                } else if resumeStartupRequiresHookSession,
                          resumeStartupSessionID == id {
                    // Claude confirmed the resumed session. Arm ready-prompt
                    // detection now; if scraping misses, release the queued
                    // prompt shortly after SessionStart rather than waiting on
                    // the longer "no SessionStart arrived" fallback.
                    resumeStartupRequiresHookSession = false
                    armResumeStartupGate(
                        sessionID: id,
                        timeout: ActivityTiming.resumedSessionPostSessionStartFallback,
                        restartWatchdog: true
                    )
                } else if resumePromptReadyTask == nil {
                    startResumePromptReadyWait(sessionID: id)
                }
            } else {
                cancelResumeStartupWatchdog()
            }
            if currentSessionID != id {
                currentSessionID = id
                sessionIDContinuation?.yield(id)
                state = .running(sessionID: id)
            }
            // Same-id SessionStart (ACP resume after engine preset the id) must
            // still reach the bus so the UI can unlock and refresh catalogs.
        case .userTurn(let id, let text):
            // Only the live UserPromptSubmit echo for *this* prompt confirms
            // acceptance. Historical transcript replay also emits `.userTurn`
            // and must not cancel recovery or clear the awaiting flag.
            if notesLivePromptAcceptance(id: id, text: text) {
                currentTurnAwaitingAcceptance = false
                currentTurnPromptText = nil
                cancelStartupSubmitRecovery()
            }
        case .permissionRequest(let prompt):
            if let rule = await prefs.matchingRule(toolName: prompt.toolName,
                                                   summary: prompt.summary) {
                do {
                    try await deliverPermissionResponse(rule.decision, for: prompt, id: prompt.id)
                    await bus.publish(.permissionAlreadyResolved(id: prompt.id, byDevice: "auto-approval"))
                    resumePollingAfterPermissionIfNeeded()
                } catch {
                    await SilentDiagnostics.shared.record(kind: .permissionDeliveryFailed,
                                                          owner: "AgentEngine",
                                                          summary: "Auto-approval delivery failed",
                                                          details: String(describing: error))
                    await bus.publish(.error(.internalInvariant(detail: "permission delivery failed: \(error)")))
                    pendingPermissions[prompt.id] = prompt
                    startPermissionTimeout(for: prompt.id)
                    await record(event)
                    await bus.publish(event)
                }
                return
            }
            pendingPermissions[prompt.id] = prompt
            startPermissionTimeout(for: prompt.id)
        case .permissionAlreadyResolved(let id, _):
            // Adapter-side resolve (e.g. migration Restart archived the session).
            // Cancel the auto-deny timer without delivering a second response.
            permissionTimeouts.removeValue(forKey: id)?.cancel()
            pendingPermissions.removeValue(forKey: id)
            resumePollingAfterPermissionIfNeeded()
        case .stopped(let reason):
            requestShutdown(reason: reason)
            return
        case .toolEnd:
            if !currentTurnAwaitingAcceptance {
                cancelStartupSubmitRecovery()
                await heartbeat?.bump(baseline: .awaitingFirstChunk)
            }
        case .assistantText:
            if currentTurnAwaitingAcceptance {
                // History (or chrome) still painting — keep the live turn alive.
                break
            }
            cancelStartupSubmitRecovery()
            if case .assistantText(let id, _, _, let isFinal) = event {
                log.debug("ingested assistantText id=\(id, privacy: .public) final=\(isFinal, privacy: .public)")
                if isFinal {
                    await heartbeat?.endTurn()
                    currentTurnID = nil
                    currentTurnPromptText = nil
                    publishIdleAfterEvent = true
                } else {
                    await heartbeat?.bump(baseline: .awaitingFirstChunk)
                }
            }
        case .activityStateChanged(.idle):
            if !currentTurnAwaitingAcceptance {
                cancelStartupSubmitRecovery()
                await heartbeat?.endTurn()
                currentTurnID = nil
                currentTurnPromptText = nil
            }
        case .textDelta:
            if !currentTurnAwaitingAcceptance {
                cancelStartupSubmitRecovery()
                await heartbeat?.bump(baseline: .streamingText)
            }
        case .toolStart:
            if !currentTurnAwaitingAcceptance {
                cancelStartupSubmitRecovery()
                await heartbeat?.bump(baseline: .runningTool)
            }
        case .thinkingChunk:
            if !currentTurnAwaitingAcceptance {
                cancelStartupSubmitRecovery()
                await heartbeat?.bump(baseline: .thinking)
            }
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
            let path = relativePath(for: url)
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

    private func startResumeStartupWatchdog(sessionID: String,
                                            timeout: Duration = ActivityTiming.resumeStartupStallTimeout) {
        cancelResumeStartupWatchdog()
        let turnID = seams.random.uuid()
        resumeStartupWatchdogTurnID = turnID
        resumeStartupWatchdogTask = Task { [weak self, clock = seams.clock] in
            do {
                try await clock.sleep(for: timeout)
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

    private func armResumeStartupGate(sessionID: String,
                                      timeout: Duration = ActivityTiming.resumeStartupStallTimeout,
                                      restartWatchdog: Bool = false) {
        resumePromptReadyEarliest = seams.clock.monotonic()
            .advanced(by: ActivityTiming.resumePromptReadySettleDelay)
        if restartWatchdog || resumeStartupWatchdogTask == nil {
            startResumeStartupWatchdog(sessionID: sessionID, timeout: timeout)
        }
        startResumePromptReadyWait(sessionID: sessionID)
    }

    private func markResumeStartupStalled(sessionID: String, turnID: UUID) async {
        guard resumeStartupSessionID == sessionID,
              resumeStartupWatchdogTurnID == turnID else { return }
        resumeStartupWatchdogTask = nil
        resumeStartupWatchdogTurnID = nil
        // Trust / permission UI: keep the send gate closed, but never leave it
        // without a live release path. Clearing the watchdog id above would
        // otherwise permanently hang every subsequent prompt.
        if !pendingPermissions.isEmpty {
            if resumePromptReadyTask == nil {
                startResumePromptReadyWait(sessionID: sessionID)
            }
            startResumeStartupWatchdog(
                sessionID: sessionID,
                timeout: resumeStartupRequiresHookSession
                    ? ActivityTiming.resumedSessionStartupStallTimeout
                    : ActivityTiming.resumeStartupStallTimeout
            )
            return
        }
        cancelResumePromptReadyWait()
        log.warning("resume startup stalled session=\(sessionID, privacy: .public)")
        // Always release the send gate. Only surface stalled-turn events when
        // nothing is waiting on that gate and no real turn has started — a user
        // who already sent into a still-booting resume must not get a fake >90s
        // gap / probablyStuck that lights the stall toast.
        let shouldSurfaceStall = currentTurnID == nil && resumeStartupWaiters.isEmpty
        if shouldSurfaceStall {
            await bus.publish(.activityStateChanged(.probablyStuck))
            await bus.publish(.noEventGap(turnID: turnID,
                                          elapsed: ActivityTiming.probablyStuckThreshold + .seconds(1)))
        }
        resumeStartupRequiresHookSession = false
        finishResumeStartupGate()
    }

    private func startResumePromptReadyWait(sessionID: String) {
        cancelResumePromptReadyWait()
        resumePromptReadySampleCount = 0
        resumePromptReadyTask = Task { [weak self, clock = seams.clock] in
            while !Task.isCancelled {
                if await self?.hasStableResumePromptReadySample(sessionID: sessionID) == true {
                    // Only exit when the gate actually finished. A session-id
                    // race can make mark a no-op; abandoning the loop then left
                    // sendPrompt blocked forever.
                    if await self?.markResumePromptReady(sessionID: sessionID) == true {
                        return
                    }
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
        if let earliest = resumePromptReadyEarliest,
           seams.clock.monotonic() < earliest {
            return false
        }
        if Self.rowsContainClaudeReadyPrompt(await terminal.snapshotRows()) {
            resumePromptReadySampleCount += 1
        } else {
            resumePromptReadySampleCount = 0
        }
        return resumePromptReadySampleCount >= Self.resumePromptReadyRequiredSamples
    }

    /// - Returns: `true` when the resume-startup gate was released.
    @discardableResult
    private func markResumePromptReady(sessionID: String) -> Bool {
        guard resumeStartupSessionID == sessionID else { return false }
        resumePromptReadyTask = nil
        resumePromptReadyEarliest = nil
        resumeStartupRequiresHookSession = false
        cancelResumeStartupWatchdog()
        log.debug("resume prompt ready session=\(sessionID, privacy: .public)")
        finishResumeStartupGate()
        return true
    }

    func armStartupSubmitRecovery(turnID: UUID, promptBytes: Data) {
        startupSubmitRecoveryAttempt = 0
        scheduleStartupSubmitRecovery(turnID: turnID, promptBytes: promptBytes)
    }

    func scheduleStartupSubmitRecovery(turnID: UUID, promptBytes: Data) {
        startupSubmitRecoveryTask?.cancel()
        startupSubmitRecoveryBytes = promptBytes
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
        guard currentTurnID == turnID else {
            cancelStartupSubmitRecovery()
            return
        }
        // Claude accepted the prompt (live `UserPromptSubmit` cleared the flag) —
        // stop retrying so we never inject a duplicate submit.
        guard currentTurnAwaitingAcceptance else {
            cancelStartupSubmitRecovery()
            return
        }
        // Never inject Enter while a trust/permission screen is awaiting the user.
        // Keep polling so recovery still runs after the dialog clears.
        guard pendingPermissions.isEmpty else {
            rescheduleStartupSubmitRecovery(turnID: turnID)
            return
        }
        guard let terminal else { return }

        // The resumed `claude --resume` process paints JSONL history and chrome
        // long after the UI already shows it, so a single post-write nudge is
        // not enough. Keep confirming delivery every tick until Claude's live
        // `UserPromptSubmit` hook clears `currentTurnAwaitingAcceptance` (which
        // cancels this loop) or the attempt budget is exhausted. We only ever
        // act on an unambiguous TUI state so an already-accepted prompt is not
        // re-submitted.
        let rows = await terminal.snapshotRows()
        if Self.rowsShowUnsubmittedPrompt(rows) {
            // Prompt text is sitting in the input row unsubmitted — press Enter.
            log.warning("startup submit recovery: re-sending Enter turn=\(turnID, privacy: .public)")
            try? await transport?.write(Data("\r".utf8))
        } else if Self.rowsContainClaudeReadyPrompt(rows),
                  let promptBytes = startupSubmitRecoveryBytes {
            // Input row is the empty ready prompt and Claude has not accepted a
            // turn (awaiting flag still set), so the earlier write was swallowed
            // during resume repaint — re-send the whole prompt.
            log.warning("startup submit recovery: re-sending prompt turn=\(turnID, privacy: .public)")
            try? await transport?.write(promptBytes)
        }
        // else: TUI still painting / working — do nothing this tick.

        startupSubmitRecoveryAttempt += 1
        if startupSubmitRecoveryAttempt < ActivityTiming.startupSubmitRecoveryMaxAttempts {
            rescheduleStartupSubmitRecovery(turnID: turnID)
        } else {
            log.warning("startup submit recovery: giving up after \(self.startupSubmitRecoveryAttempt, privacy: .public) attempts turn=\(turnID, privacy: .public)")
            // Stop gating turn completion so a late assistant reply / idle can
            // still finish the turn normally instead of wedging it open.
            currentTurnAwaitingAcceptance = false
            currentTurnPromptText = nil
            cancelStartupSubmitRecovery()
        }
    }

    private func rescheduleStartupSubmitRecovery(turnID: UUID) {
        guard let promptBytes = startupSubmitRecoveryBytes else { return }
        scheduleStartupSubmitRecovery(turnID: turnID, promptBytes: promptBytes)
    }

    func cancelStartupSubmitRecovery() {
        startupSubmitRecoveryTask?.cancel()
        startupSubmitRecoveryTask = nil
        startupSubmitRecoveryBytes = nil
        startupSubmitRecoveryAttempt = 0
    }

    /// True when `text` is the live prompt we just submitted (hook echo), not
    /// an unrelated historical transcript turn.
    private func notesLivePromptAcceptance(id: String, text: String) -> Bool {
        guard id == currentSessionID else { return false }
        if let expected = currentTurnPromptText { return text == expected }
        guard let bytes = startupSubmitRecoveryBytes,
              var expected = String(data: bytes, encoding: .utf8) else { return false }
        while expected.hasSuffix("\r") || expected.hasSuffix("\n") {
            expected.removeLast()
        }
        return text == expected
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

    /// After a trust/permission dialog clears, ensure the resume-startup gate
    /// still has a path to open (ready poll + watchdog). Without this, a
    /// watchdog tick that saw pending permissions can leave sends blocked.
    func resumePollingAfterPermissionIfNeeded() {
        guard let sessionID = resumeStartupSessionID, pendingPermissions.isEmpty else { return }
        if resumePromptReadyTask == nil {
            startResumePromptReadyWait(sessionID: sessionID)
        }
        if resumeStartupWatchdogTask == nil {
            startResumeStartupWatchdog(sessionID: sessionID)
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

        do {
            try await deliverPermissionResponse(.deny, for: prompt, id: id)
            await bus.publish(.permissionAlreadyResolved(id: id, byDevice: "timeout"))
            await bus.publish(.error(.permissionTimeout(promptID: id, action: .deny)))
            resumePollingAfterPermissionIfNeeded()
        } catch {
            await SilentDiagnostics.shared.record(kind: .permissionDeliveryFailed,
                                                  owner: "AgentEngine",
                                                  summary: "Permission delivery failed on timeout",
                                                  details: String(describing: error))
            await bus.publish(.error(.internalInvariant(detail: "permission delivery failed: \(error)")))
        }
    }

    func deliverPermissionResponse(_ decision: PermissionDecision,
                                   for prompt: PermissionPrompt,
                                   id: UUID) async throws {
        guard let adapter else { return }
        switch adapter.encodePermissionResponse(decision, for: prompt) {
        case .writePTY(let data):
            try await transport?.write(data)
        case .respondToHookProcess(let json):
            await hookServer?.respond(to: id, with: json)
        case .both(let ptyBytes, let hookOut):
            try await transport?.write(ptyBytes)
            await hookServer?.respond(to: id, with: hookOut)
        }
    }

    // MARK: - Filesystem diff monitor

    private func startFSWatcher(workspace: URL) async {
        let watcher = FSEventsWatcher(workspace: workspace)
        do {
            try await watcher.start()
        } catch {
            await SilentDiagnostics.shared.record(kind: .other,
                                                  owner: "AgentEngine",
                                                  summary: "FSEvents watcher failed to start",
                                                  details: String(describing: error))
            return
        }
        fsWatcher = watcher
        fsWatcherTask = Task { [weak self] in
            for await _ in watcher.events {
                await self?.scheduleDiffRefresh()
            }
        }
        await refreshChangedFilesFromGit()
    }

    private func stopFSWatcher() async {
        diffRefreshTask?.cancel()
        diffRefreshTask = nil
        fsWatcherTask?.cancel()
        fsWatcherTask = nil
        await fsWatcher?.stop()
        fsWatcher = nil
    }

    private func scheduleDiffRefresh() {
        diffRefreshTask?.cancel()
        diffRefreshTask = Task { [weak self, clock = seams.clock] in
            do {
                try await clock.sleep(for: Self.diffRefreshCoalesce)
            } catch {
                return
            }
            await self?.refreshChangedFilesFromGit()
        }
    }

    private func refreshChangedFilesFromGit() async {
        guard let workspace else { return }
        let diffEngine = GitDiffEngine(workspace: workspace)
        guard let gitPaths = try? await diffEngine.changedFiles() else { return }
        let delta = ChangedFilesReconciler.reconcile(current: changedFiles, gitPaths: gitPaths)
        changedFiles = delta.next
        for path in delta.added {
            let url = workspace.appendingPathComponent(path)
            await bus.publish(.fileTouched(url, kind: .fsObserved))
        }
        for path in delta.removed {
            await bus.publish(.fileReverted(path: path))
        }
    }

    private func relativePath(for url: URL) -> String {
        guard let workspace else { return url.path }
        let workspacePath = workspace.standardizedFileURL.path
        let filePath = url.standardizedFileURL.path
        if filePath.hasPrefix(workspacePath + "/") {
            return String(filePath.dropFirst(workspacePath.count + 1))
        }
        if filePath == workspacePath { return url.lastPathComponent }
        return url.path
    }

    private static func errno(from error: any Error) -> Int32 {
        if let pty = error as? PTYError {
            switch pty {
            case .spawnFailed(let e, _): return e
            case .openptyFailed(let e): return e
            case .setWinsizeFailed(let e): return e
            case .writeFailed(let e): return e
            case .alreadyClosed: return -1
            }
        }
        if error is AgentTransportError {
            return -1
        }
        return -1
    }

}
