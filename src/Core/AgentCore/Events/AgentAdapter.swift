import Foundation
import AgentProtocol

/// Raw signal sources the adapter consumes. The engine populates streams from
/// the bound `AgentTransport`; terminal snapshots are optional (nil for
/// non-terminal transports such as Codex App Server).
public struct AgentInputs: Sendable {
    public let outputBytes: AsyncStream<Data>
    public let writeBytes: @Sendable (Data) async throws -> Void
    public let terminal: (any TerminalSnapshotting)?
    public let hookSocket: HookSocketHandle?
    public let workspace: URL
    public let resumeSessionID: String?
    public let sessionID: AsyncStream<String>
    public let recordBackgroundSessionEvents: @Sendable (BackgroundSessionEventBatch) async -> Void
    public let updateSessionMetadata: @Sendable (SessionMetadataUpdate) async -> Void

    public init(outputBytes: AsyncStream<Data>,
                writeBytes: @escaping @Sendable (Data) async throws -> Void = { _ in },
                terminal: (any TerminalSnapshotting)?,
                hookSocket: HookSocketHandle?,
                workspace: URL,
                resumeSessionID: String? = nil,
                sessionID: AsyncStream<String>,
                recordBackgroundSessionEvents: @escaping @Sendable (BackgroundSessionEventBatch) async -> Void = { _ in },
                updateSessionMetadata: @escaping @Sendable (SessionMetadataUpdate) async -> Void = { _ in }) {
        self.outputBytes = outputBytes
        self.writeBytes = writeBytes
        self.terminal = terminal
        self.hookSocket = hookSocket
        self.workspace = workspace
        self.resumeSessionID = resumeSessionID
        self.sessionID = sessionID
        self.recordBackgroundSessionEvents = recordBackgroundSessionEvents
        self.updateSessionMetadata = updateSessionMetadata
    }
}

/// Opaque handle to an active hook UDS connection. Each hook invocation is a
/// short-lived request; the adapter responds with stdout bytes.
public struct HookSocketHandle: Sendable {
    public let incoming: AsyncStream<HookRequest>
    public let respond: @Sendable (HookRequestID, Data) async -> Void

    public init(incoming: AsyncStream<HookRequest>,
                respond: @escaping @Sendable (HookRequestID, Data) async -> Void) {
        self.incoming = incoming
        self.respond = respond
    }
}

/// Identity of one open hook connection.
///
/// Minted per accepted UDS connection and used as the key of the server's
/// pending-response table, so it names a live socket rather than anything in
/// the conversation. It outlives the request only until the reply is written.
public struct HookRequestID: RawRepresentable, Sendable, Codable, Hashable {
    public let rawValue: UUID

    public init(rawValue: UUID) {
        self.rawValue = rawValue
    }
}

/// One inbound hook request as decoded from the UDS connection.
public struct HookRequest: Sendable, Hashable, Identifiable {
    public let id: HookRequestID
    public let eventName: String
    public let jsonPayload: Data

    public init(id: HookRequestID, eventName: String, jsonPayload: Data) {
        self.id = id
        self.eventName = eventName
        self.jsonPayload = jsonPayload
    }
}

/// One filesystem event from FSEvents, normalised to a URL + a coarse kind.
public struct FSEvent: Sendable, Hashable {
    public enum Kind: Sendable, Hashable { case modified, created, removed, renamed }
    public let url: URL
    public let kind: Kind
    public let observedAt: Date

    public init(url: URL, kind: Kind, observedAt: Date) {
        self.url = url
        self.kind = kind
        self.observedAt = observedAt
    }
}

/// Read-only view into the headless VT screen. Backed by `TerminalEngine` in
/// production; backed by a fake in tests. Protocol so the adapter doesn't
/// import SwiftTerm.
public protocol TerminalSnapshotting: Sendable {
    /// Currently visible rows, ANSI-stripped, trailing spaces trimmed.
    func snapshotRows() async -> [String]

    /// Concatenated snapshot as a single string with `\n` separators.
    func snapshotText() async -> String
}

/// The single protocol every CLI agent implements.
public protocol AgentAdapter: Sendable {

    // MARK: Identity

    var id: AgentID { get }
    var displayName: String { get }
    /// SF Symbol shown by UI surfaces that represent this adapter.
    var iconSymbol: String { get }

    // MARK: Discovery & launch

    func locateBinary(env: ResolvedEnvironment) async throws -> URL
    func defaultEnvOverrides() -> [String: String]
    func buildLaunchArgv(context: LaunchContext) -> [String]

    /// Transport strategy for this adapter. The engine binds a matching
    /// `AgentTransport` via `AgentTransportFactory`.
    var transportDescriptor: AgentTransportDescriptor { get }

    // MARK: Authentication

    func authStatus(env: ResolvedEnvironment) async -> AuthStatus

    // MARK: Capability declaration

    var capabilities: AgentCapabilities { get }

    // MARK: Event stream

    func makeEventStream(inputs: AgentInputs) -> AsyncStream<AgentEvent>

    // MARK: Input encoding

    func encodeUserPrompt(_ text: String) -> Data
    func cancelSequence() -> Data

    /// Bytes written immediately after the transport is live (handshake /
    /// bootstrap). Default empty — terminal agents typically need nothing;
    /// stdio JSON-RPC agents (Codex) send `initialize` + `thread/start`.
    func sessionBootstrapBytes(context: LaunchContext) -> Data

    /// Encode a non-prompt engine command into transport bytes. Return `nil`
    /// when the adapter does not support the command; the engine surfaces an
    /// explicit unsupported-command error rather than silently skipping.
    func encodeCommand(_ command: AgentCommand) -> Data?

    /// Encode a same-process session resume/load (ACP `session/load`). Return
    /// `nil` when the adapter cannot warm-switch sessions without a respawn.
    /// Used by `openProject` to avoid Cursor's ~20s cold handshake when the
    /// agent process is already live on the same workspace.
    func encodeResumeSession(sessionID: String) -> Data?

    // MARK: Permission responses

    func encodePermissionResponse(_ decision: PermissionDecision,
                                  for prompt: PermissionPrompt) -> PermissionResponseDelivery

    /// When non-nil, the engine applies this decision silently without
    /// surfacing the prompt to the UI. Adapters use this for gates that are
    /// already decided by opening the project in Codemixer (e.g. Claude Code
    /// folder trust). Default `nil` — prefs auto-approval still applies.
    func autoAllowDecision(for prompt: PermissionPrompt) -> PermissionDecision?

    // MARK: Slash commands

    var slashCommandCatalog: [SlashCommand] { get }
    func enumerateProjectCommands(workspace: URL) async -> [SlashCommand]

    // MARK: Sessions

    /// Stable directory namespace for Codemixer-owned history.
    var historyNamespace: String { get }
    /// One-shot vendor catalog import used only when an existing project is
    /// added to a workspace.
    func importSessionCatalog(
        workspace: URL,
        env: ResolvedEnvironment,
        progress: @escaping @Sendable (Int, Int) async -> Void
    ) async throws -> [ImportedSession]
    func resumeArgvAddition(sessionID: String) -> [String]

    // MARK: Model catalog

    /// Models the adapter exposes for composer / toolbar selection. Default
    /// empty — adapters with a `/model` command override.
    func availableModels() -> [AgentModelOption]

    /// Whether model discovery is automatic or requires an explicit refresh.
    func modelCatalogRefreshKind() -> ModelCatalogRefreshKind

    /// Re-query the agent for models. Default returns `availableModels()`.
    /// Manual adapters (Claude Code) override with a live discovery probe.
    func refreshModelCatalog() async throws -> [AgentModelOption]

    /// Replace the in-memory catalog without probing (workspace cache hydrate).
    func seedModelCatalog(_ models: [AgentModelOption])

    // MARK: Agent modes

    /// Agent modes for the composer bottom-bar dropdown (Cursor agent/plan/ask,
    /// Claude Think/Review, …). Default empty — each shipping adapter publishes
    /// its own list. Distinct from `ProjectType`.
    func availableAgentModes() -> [AgentModeOption]

    // MARK: Hook configuration (optional)

    /// Called after the engine starts a `HookServer` but before the agent is
    /// spawned. Adapters that declare `.hooksOverUDS` use this to install
    /// per-workspace configuration so the spawned agent talks to our socket.
    /// Default no-op.
    func installHookConfiguration(socketPath: String,
                                  workspace: URL,
                                  fileSystem: any FileSystem) async throws

    /// How long the engine should let a freshly spawned agent settle after it
    /// reports prompt readiness, before writing a prompt it did not ask for.
    ///
    /// Protocol adapters answer `.zero`: a JSON-RPC peer that has replied to
    /// `initialize` can take a request. Interactive TUIs need more — their
    /// session hook fires while the input row is still being painted, and
    /// keystrokes that arrive first are dropped with no error.
    var promptWriteSettleDelay: Duration { get }

    // MARK: Transcript management (optional)

    /// Truncate the persisted conversation transcript so it ends just after the
    /// user turn identified by `turnID`. Called during edit-and-resubmit to
    /// strip the assistant's (potentially partial) response before the session
    /// is respawned with `--resume`.
    ///
    /// Returns `true` if truncation succeeded and the caller may respawn with
    /// the same session ID. The default no-op returns `false`, signalling that
    /// the caller should fall back to a fresh session.
    func truncateTranscript(afterUserTurnID turnID: AdapterTurnID,
                            sessionID: String,
                            workspace: URL) async -> Bool

    // MARK: A2UI (optional)

    /// Encode a resolved `client_to_server` action for the wire. `nil` means
    /// this adapter has no A2UI transport binding — the engine surfaces
    /// `.unsupportedCommand` rather than silently dropping the interaction.
    func encodeA2UIAction(_ envelope: A2UIActionEnvelope) -> Data?

    /// Encode a `client_to_server` error report for the wire. Default `nil`.
    func encodeA2UIClientError(_ envelope: A2UIClientErrorEnvelope) -> Data?
}

public extension AgentAdapter {
    var historyNamespace: String { id.rawValue }

    func importSessionCatalog(
        workspace: URL,
        env: ResolvedEnvironment,
        progress: @escaping @Sendable (Int, Int) async -> Void
    ) async throws -> [ImportedSession] {
        []
    }

    func installHookConfiguration(socketPath: String,
                                  workspace: URL,
                                  fileSystem: any FileSystem) async throws {}

    func truncateTranscript(afterUserTurnID turnID: AdapterTurnID,
                            sessionID: String,
                            workspace: URL) async -> Bool { false }

    var promptWriteSettleDelay: Duration { .zero }

    func encodeA2UIAction(_ envelope: A2UIActionEnvelope) -> Data? { nil }

    func encodeA2UIClientError(_ envelope: A2UIClientErrorEnvelope) -> Data? { nil }

    func availableModels() -> [AgentModelOption] { [] }

    func modelCatalogRefreshKind() -> ModelCatalogRefreshKind { .automatic }

    func refreshModelCatalog() async throws -> [AgentModelOption] {
        availableModels()
    }

    func seedModelCatalog(_ models: [AgentModelOption]) {}

    func availableAgentModes() -> [AgentModeOption] { [] }

    func sessionBootstrapBytes(context: LaunchContext) -> Data { Data() }

    func encodeResumeSession(sessionID: String) -> Data? { nil }

    func autoAllowDecision(for prompt: PermissionPrompt) -> PermissionDecision? { nil }

    /// Default encodes Claude-compatible slash text for the common command
    /// set. Non-terminal adapters override with protocol frames.
    func encodeCommand(_ command: AgentCommand) -> Data? {
        let line: String
        switch command {
        case .newSession:          line = "/clear\n"
        case .compact:             line = "/compact\n"
        case .selectModel(let id): line = "/model \(id)\n"
        case .setPermissionMode(let m): line = "/permission \(m.rawValue)\n"
        case .setAgentMode(let id):
            switch id {
            case AgentModeCommandID.think:
                line = "/think\n"
            case AgentModeCommandID.thinkOff:
                line = "/think off\n"
            case AgentModeCommandID.review:
                line = "/review\n"
            case AgentModeCommandID.reviewOff:
                line = "/review off\n"
            default:
                return nil
            }
        case .runSlashCommand(let target, let args):
            line = ([target.commandText] + args).joined(separator: " ") + "\n"
        default:
            return nil
        }
        return encodeUserPrompt(line)
    }
}

/// Process-wide registry. UI surfaces resolve adapters through this rather
/// than importing concrete adapter targets; the engine looks up adapters by id
/// when resuming a session.
///
/// Registration stores a **factory** so each pooled runtime can own a fresh
/// adapter instance (Codex/ACP client state must not be shared across slots).
/// `adapter(for:)` / `all()` return catalog instances for listing and
/// capabilities; `makeAdapter(for:)` always constructs a new runtime instance.
public actor AdapterRegistry {
    public static let shared = AdapterRegistry()

    public typealias Factory = @Sendable () -> any AgentAdapter

    private var factories: [AgentID: Factory] = [:]
    /// Lazily retained catalog adapters for `adapter(for:)` / `all()`.
    private var catalog: [AgentID: any AgentAdapter] = [:]

    public init() {}

    /// Register a factory that produces a new adapter instance per call.
    public func register(id: AgentID, factory: @escaping Factory) {
        factories[id] = factory
        catalog[id] = nil
    }

    /// Convenience for tests and simple adapters: wraps a single instance as a
    /// factory that returns that same instance (shared). Prefer `register(id:factory:)`
    /// in production Bootstrap so pool slots get isolated state.
    public func register(_ adapter: any AgentAdapter) {
        let id = adapter.id
        factories[id] = { adapter }
        catalog[id] = adapter
    }

    /// Catalog / capability lookup — may reuse a retained instance.
    public func adapter(for id: AgentID) -> (any AgentAdapter)? {
        if let existing = catalog[id] { return existing }
        guard let factory = factories[id] else { return nil }
        let made = factory()
        catalog[id] = made
        return made
    }

    /// Fresh instance for a pooled runtime spawn.
    public func makeAdapter(for id: AgentID) -> (any AgentAdapter)? {
        factories[id]?()
    }

    public func all() -> [any AgentAdapter] {
        for id in factories.keys where catalog[id] == nil {
            _ = adapter(for: id)
        }
        return Array(catalog.values).sorted { $0.displayName < $1.displayName }
    }
}
