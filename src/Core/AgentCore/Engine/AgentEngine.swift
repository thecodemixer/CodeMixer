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

    enum TeardownMode {
        case shutdown(reason: AgentProtocol.StopReason)
        case rollbackPartialStart
    }

    enum TurnState: Sendable, Equatable {
        case idle
        case active(id: UUID)

        var id: UUID? {
            if case .active(let id) = self { return id }
            return nil
        }
    }

    enum SessionTeardownState: Sendable, Equatable {
        case idle
        case inFlight
    }

    enum SessionActivationState: Sendable, Equatable {
        case idle
        case restoring(SessionTranscriptKey)
        case awaitingAdapter(SessionTranscriptKey, historyPublished: Bool)
        case ready(SessionTranscriptKey)
        case failed(SessionTranscriptKey, AgentError)
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
    var hookServer: HookServer?
    var sessionIDContinuation: AsyncStream<String>.Continuation?
    var currentSessionID: String?

    /// Sticky per-project agent process pool. `adapter`/`transport`/… mirror the
    /// active runtime; parked entries keep their own forwarding tasks alive.
    var runtimes: [AgentRuntimeKey: AgentRuntime] = [:]
    var activeKey: AgentRuntimeKey?
    private var turnState: TurnState = .idle
    var currentTurnID: UUID? {
        get { turnState.id }
        set {
            turnState = newValue.map { .active(id: $0) } ?? .idle
        }
    }
    var pendingPermissions: [UUID: PermissionPrompt] = [:]
    var lastUserBubbleID: UUID?
    var heartbeat: HeartbeatActivityMonitor?
    private var phraseResolver: StatusPhraseResolver
    var eventForwardingTask: Task<Void, Never>?
    var bellTask: Task<Void, Never>?
    var sessionTeardownState: SessionTeardownState = .idle
    var workspace: URL?
    var sessionActivationState: SessionActivationState = .idle
    var pendingTranscriptEvents: [AgentEvent] = []
    var attentionSessionIDsByProject: [String: Set<String>] = [:]
    var transcript: [SnapshotService.SnapshotMessage] = []
    var changedFiles: [ChangedFile] = []
    var permissionTimeouts: [UUID: Task<Void, Never>] = [:]
    private var fsWatcher: FSEventsWatcher?
    private var fsWatcherTask: Task<Void, Never>?
    private var diffRefreshTask: Task<Void, Never>?

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
    nonisolated let transcriptRepository: SessionTranscriptRepository
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
        self.transcriptRepository = SessionTranscriptRepository(
            store: ProjectSessionTranscriptStore(fileSystem: seams.fileSystem),
            clock: seams.clock
        )
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
        guard let terminal = transport?.terminalSnapshot else { return "" }
        return await terminal.snapshotText()
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
        let key = AgentRuntimeKey(projectPath: workspace.path,
                                  agentID: adapter.id,
                                  instance: .shared)
        try await start(adapter: adapter,
                        workspace: workspace,
                        resumeSessionID: resumeSessionID,
                        permissionMode: permissionMode,
                        runtimeKey: key)
    }

    /// Start (or replace) a pooled runtime for `runtimeKey` and make it active.
    func start(adapter: any AgentAdapter,
               workspace: URL,
               resumeSessionID: String? = nil,
               permissionMode: PermissionMode = .default,
               runtimeKey: AgentRuntimeKey) async throws {
        // Park any other active slot; replace this key if it already exists.
        if let active = activeKey, active != runtimeKey {
            await parkActive()
        }
        if runtimes[runtimeKey] != nil {
            await shutdownSlot(runtimeKey, publishStopped: false)
        } else if state != .stopped, activeKey == nil, runtimes.isEmpty {
            // Legacy single-slot: engine claimed running without pool entry.
            await teardownActiveMirror(.rollbackPartialStart)
        }

        state = .starting
        self.adapter = adapter
        // Always standardize so UI cwd filtering matches ACP `sessionStarted`.
        let workspace = workspace.standardizedFileURL
        self.workspace = workspace
        if resumeSessionID == nil {
            self.transcript = []
            self.changedFiles = []
            sessionActivationState = .awaitingAdapter(
                SessionTranscriptKey(projectRoot: workspace,
                                     namespace: adapter.historyNamespace,
                                     sessionID: ""),
                historyPublished: true
            )
        }
        activeKey = runtimeKey

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

        // Optional hook server — one UDS per Claude (hooks) project slot.
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
            await rollbackPartialStart(key: runtimeKey)
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
            await rollbackPartialStart(key: runtimeKey)
            throw AgentError.spawnFailed(errno: Self.errno(from: error),
                                         detail: String(describing: error))
        }
        self.transport = transport

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
                                 sessionID: sessionIDStream,
                                 recordBackgroundSessionEvents: { [weak self] batch in
                                     await self?.recordBackgroundSessionEvents(
                                         batch,
                                         adapter: adapter,
                                         workspace: workspace
                                     )
                                 },
                                 updateSessionMetadata: { [weak self] update in
                                     await self?.updateSessionMetadata(
                                         update,
                                         adapter: adapter,
                                         workspace: workspace
                                     )
                                 })

        let adapterStream = adapter.makeEventStream(inputs: inputs)

        // Heartbeat activity monitor — server-side, drives `noEventGap`.
        let monitor = HeartbeatActivityMonitor(clock: seams.clock) { [weak self] tick in
            await self?.onHeartbeat(tick)
        }
        self.heartbeat = monitor

        state = .running(sessionID: resumeSessionID)
        log.notice("engine started workspace=\(workspace.path, privacy: .public) key=\(runtimeKey.projectPath, privacy: .public)")
        // Forward adapter events onto the bus, with bookkeeping side-effects.
        let forwarding = Task { [weak self] in
            for await event in adapterStream {
                await self?.ingest(event, from: runtimeKey)
            }
        }
        eventForwardingTask = forwarding

        // Bell fan-out — empty stream for non-terminal transports finishes immediately.
        let bells = transport.bellEvents
        let bellsTask = Task { [weak self] in
            for await _ in bells {
                guard let self, await self.activeKey == runtimeKey else { continue }
                await self.bus.publish(.bell)
            }
        }
        bellTask = bellsTask

        runtimes[runtimeKey] = AgentRuntime(
            key: runtimeKey,
            adapter: adapter,
            transport: transport,
            hookServer: hookServer,
            workspace: workspace,
            boundSessionID: resumeSessionID,
            forwardingTask: forwarding,
            bellTask: bellsTask,
            sessionIDContinuation: sessionIDContinuation,
            lastActivatedAt: seams.clock.now()
        )

        let bootstrap = adapter.sessionBootstrapBytes(context: context)
        if !bootstrap.isEmpty {
            do {
                try await transport.write(bootstrap)
            } catch {
                await rollbackPartialStart(key: runtimeKey)
                throw AgentError.spawnFailed(errno: Self.errno(from: error),
                                             detail: "bootstrap write failed: \(error)")
            }
        }

        await startFSWatcher(workspace: workspace)
        await publishRuntimePoolChanged()
    }

    /// Shut down every pooled runtime. Idempotent. Used for workspace close /
    /// daemon idle / public `shutdown`.
    public func shutdown(reason: AgentProtocol.StopReason = .userCancel) async {
        await shutdownAll(reason: reason)
        try? await transcriptRepository.shutdown()
    }

    /// Tear down a partially started session without publishing `.stopped`.
    private func rollbackPartialStart(key: AgentRuntimeKey) async {
        await shutdownSlot(key, publishStopped: false)
        await SilentDiagnostics.shared.record(kind: .enginePartialStartRollback,
                                              owner: "AgentEngine",
                                              summary: "Rolled back partial engine start")
        if runtimes.isEmpty {
            state = .stopped
            activeKey = nil
        }
    }

    func teardownActiveMirror(_ mode: TeardownMode) async {
        eventForwardingTask?.cancel()
        eventForwardingTask = nil
        bellTask?.cancel()
        bellTask = nil
        await stopFSWatcher()
        await transport?.close()
        transport = nil
        await hookServer?.stop()
        hookServer = nil
        sessionIDContinuation?.finish()
        sessionIDContinuation = nil
        await heartbeat?.endTurn()
        heartbeat = nil
        adapter = nil
        workspace = nil
        currentSessionID = nil
        currentTurnID = nil
        pendingPermissions.removeAll()
        lastUserBubbleID = nil
        for task in permissionTimeouts.values { task.cancel() }
        permissionTimeouts.removeAll()
        if case .rollbackPartialStart = mode {
            transcript = []
            changedFiles = []
        }
        await phraseResolver.reset()
        switch mode {
        case .shutdown(let reason):
            await bus.publish(.stopped(reason: reason))
            state = .stopped
            sessionTeardownState = .idle
            log.notice("engine stopped reason=\(String(describing: reason), privacy: .public)")
        case .rollbackPartialStart:
            state = .stopped
        }
    }

    /// Serialize adapter-driven shutdown so nested ingest/shutdown races cannot
    /// double-stop or cancel the forwarding task mid-flight.
    private func requestShutdown(reason: StopReason, for key: AgentRuntimeKey) {
        Task { [weak self] in
            await self?.shutdownSlot(key, publishStopped: true, reason: reason)
        }
    }

    // MARK: - Internal — adapter event ingestion

    func ingest(_ event: AgentEvent, from key: AgentRuntimeKey) async {
        let isActive = activeKey == key
        // Parked runtimes keep recording durable events, while only attention
        // and permission state reach the foreground bus.
        if !isActive {
            if let runtime = runtimes[key], let sessionID = runtime.boundSessionID {
                await recordBackgroundSessionEvents(
                    .init(sessionID: sessionID, events: [event]),
                    adapter: runtime.adapter,
                    workspace: runtime.workspace
                )
            }
            switch event {
            case .sessionAttentionChanged, .permissionRequest, .permissionAlreadyResolved:
                break
            case .stopped(let reason):
                requestShutdown(reason: reason, for: key)
                return
            default:
                return
            }
        }

        var publishIdleAfterEvent = false
        var promptReadySessionID: String?
        // Update bookkeeping before broadcasting.
        switch event {
        case .sessionStarted(let id, _, _):
            if currentSessionID != id {
                currentSessionID = id
                sessionIDContinuation?.yield(id)
                state = .running(sessionID: id)
            }
            if var runtime = runtimes[key] {
                runtime.boundSessionID = id
                runtimes[key] = runtime
            }
            await bindTranscriptSession(id)
            promptReadySessionID = id
            // Same-id SessionStart (ACP resume after engine preset the id) must
            // still reach the bus so the UI can unlock and refresh catalogs.
        case .permissionRequest(let prompt):
            // Adapter-owned gates (e.g. Claude folder trust) that are already
            // decided by opening the project — apply silently via the same
            // encode/delivery path as a user Allow.
            if let decision = adapter?.autoAllowDecision(for: prompt) {
                do {
                    try await deliverPermissionResponse(decision, for: prompt, id: prompt.id)
                    await bus.publish(.permissionAlreadyResolved(id: prompt.id,
                                                                 byDevice: "adapter-auto"))
                } catch {
                    await SilentDiagnostics.shared.record(
                        kind: .permissionDeliveryFailed,
                        owner: "AgentEngine",
                        summary: "Adapter auto-allow delivery failed",
                        details: String(describing: error)
                    )
                    pendingPermissions[prompt.id] = prompt
                    startPermissionTimeout(for: prompt.id)
                    await record(event)
                    await bus.publish(event)
                }
                return
            }
            if let rule = await prefs.matchingRule(toolName: prompt.toolName,
                                                   summary: prompt.summary) {
                do {
                    try await deliverPermissionResponse(rule.decision, for: prompt, id: prompt.id)
                    await bus.publish(.permissionAlreadyResolved(id: prompt.id, byDevice: "auto-approval"))
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
        case .sessionAttentionChanged(let sessionID, _, let needsAttention):
            let projectRoot = runtimes[key]?.workspace ?? workspace
            if let projectRoot {
                noteSessionAttention(sessionID,
                                     needsAttention: needsAttention,
                                     in: projectRoot)
            }
        case .stopped(let reason):
            requestShutdown(reason: reason, for: key)
            return
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
        if let promptReadySessionID {
            await markSessionPromptReady(promptReadySessionID)
        }
        if publishIdleAfterEvent {
            await bus.publish(.activityStateChanged(.idle))
        }
    }

    func record(_ event: AgentEvent) async {
        await persistTranscriptEvent(event)
        switch event {
        case .userTurn(_, let text):
            if transcript.last?.role != .user || transcript.last?.text != text {
                transcript.append(.init(role: .user, text: text, timestamp: seams.clock.now()))
            }
        case .assistantText(_, _, let text, let isFinal) where isFinal:
            transcript.append(.init(role: .assistant, text: text, timestamp: seams.clock.now()))
        case .fileTouched(let url, _):
            let file = ChangedFile(url: url, workspace: workspace)
            if !changedFiles.contains(file) { changedFiles.append(file) }
        default:
            break
        }
    }

    func onHeartbeat(_ tick: HeartbeatActivityMonitor.Tick) async {
        guard let turn = currentTurnID else { return }
        await bus.publish(.noEventGap(turnID: turn, elapsed: tick.elapsed))
        await bus.publish(.activityStateChanged(tick.substate))
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

    func startFSWatcher(workspace: URL) async {
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
        await refreshChangedFilesFromGit(for: activeKey)
    }

    func stopFSWatcher() async {
        diffRefreshTask?.cancel()
        diffRefreshTask = nil
        fsWatcherTask?.cancel()
        fsWatcherTask = nil
        await fsWatcher?.stop()
        fsWatcher = nil
    }

    private func scheduleDiffRefresh() {
        diffRefreshTask?.cancel()
        let origin = activeKey
        diffRefreshTask = Task { [weak self, clock = seams.clock] in
            do {
                try await clock.sleep(for: Self.diffRefreshCoalesce)
            } catch {
                return
            }
            await self?.refreshChangedFilesFromGit(for: origin)
        }
    }

    /// Reconcile the changed-file mirror against `git status` for the runtime
    /// that asked for the refresh.
    ///
    /// `origin` is what makes the result attributable. `git status` is a
    /// subprocess, so the engine services a project switch while it runs, and
    /// activation resets `changedFiles` and rebinds `workspace`. Without the
    /// pre- and post-await checks, a refresh started for the outgoing project
    /// lands on the incoming one: its files become the new project's changed
    /// set and each one is published as `.fileTouched` against the wrong
    /// workspace.
    func refreshChangedFilesFromGit(for origin: AgentRuntimeKey?) async {
        guard let workspace, activeKey == origin else { return }
        let diffEngine = GitDiffEngine(workspace: workspace)
        guard let gitFiles = try? await diffEngine.changedFiles() else { return }
        guard activeKey == origin, self.workspace == workspace else { return }
        let delta = ChangedFilesReconciler.reconcile(current: changedFiles, gitPaths: gitFiles)
        changedFiles = delta.next
        for file in delta.added {
            let url = workspace.appendingPathComponent(file.relativePath)
            await bus.publish(.fileTouched(url, kind: .fsObserved))
        }
        for file in delta.removed {
            await bus.publish(.fileReverted(file: file))
        }
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
