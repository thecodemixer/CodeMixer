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

    public init(outputBytes: AsyncStream<Data>,
                writeBytes: @escaping @Sendable (Data) async throws -> Void = { _ in },
                terminal: (any TerminalSnapshotting)?,
                hookSocket: HookSocketHandle?,
                workspace: URL,
                resumeSessionID: String? = nil,
                sessionID: AsyncStream<String>) {
        self.outputBytes = outputBytes
        self.writeBytes = writeBytes
        self.terminal = terminal
        self.hookSocket = hookSocket
        self.workspace = workspace
        self.resumeSessionID = resumeSessionID
        self.sessionID = sessionID
    }
}

/// Opaque handle to an active hook UDS connection. Each hook invocation is a
/// short-lived request; the adapter responds with stdout bytes.
public struct HookSocketHandle: Sendable {
    public let incoming: AsyncStream<HookRequest>
    public let respond: @Sendable (UUID, Data) async -> Void

    public init(incoming: AsyncStream<HookRequest>,
                respond: @escaping @Sendable (UUID, Data) async -> Void) {
        self.incoming = incoming
        self.respond = respond
    }
}

/// One inbound hook request as decoded from the UDS connection.
public struct HookRequest: Sendable, Hashable, Identifiable {
    public let id: UUID
    public let eventName: String
    public let jsonPayload: Data

    public init(id: UUID, eventName: String, jsonPayload: Data) {
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

/// Live input-row state scraped from a headless VT snapshot.
///
/// `.ptyTUIFallback` adapters classify their own prompt chrome so the engine
/// can gate resume writes and recover swallowed first prompts without knowing
/// vendor glyphs (`❯`, Ink footers, …).
public enum TerminalInputState: Sendable, Hashable {
    /// No heuristic, or the snapshot is ambiguous (painting / unknown chrome).
    case unknown
    /// Empty ready prompt — safe to write the next prompt.
    case ready
    /// Input row still holds unsubmitted text — recovery should send Enter.
    case unsubmitted
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

    // MARK: Terminal input classification (optional TUI)

    /// Classify the live input row from a headless VT snapshot. Used by the
    /// engine's resume-startup gate and first-prompt submit recovery for
    /// `.ptyTUIFallback` adapters. Default `.unknown` (no scrape).
    func classifyTerminalInput(rows: [String]) -> TerminalInputState

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

    // MARK: Slash commands

    var slashCommandCatalog: [SlashCommand] { get }
    func enumerateProjectCommands(workspace: URL) async -> [SlashCommand]

    // MARK: Sessions

    func listResumableSessions(workspace: URL) async -> [SessionSummary]
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

    // MARK: Transcript management (optional)

    /// Truncate the persisted conversation transcript so it ends just after the
    /// user turn identified by `turnID`. Called during edit-and-resubmit to
    /// strip the assistant's (potentially partial) response before the session
    /// is respawned with `--resume`.
    ///
    /// Returns `true` if truncation succeeded and the caller may respawn with
    /// the same session ID. The default no-op returns `false`, signalling that
    /// the caller should fall back to a fresh session.
    func truncateTranscript(afterUserTurnID turnID: String,
                            sessionID: String,
                            workspace: URL) async -> Bool
}

public extension AgentAdapter {
    func installHookConfiguration(socketPath: String,
                                  workspace: URL,
                                  fileSystem: any FileSystem) async throws {}

    func truncateTranscript(afterUserTurnID turnID: String,
                            sessionID: String,
                            workspace: URL) async -> Bool { false }

    func classifyTerminalInput(rows: [String]) -> TerminalInputState { .unknown }

    func availableModels() -> [AgentModelOption] { [] }

    func modelCatalogRefreshKind() -> ModelCatalogRefreshKind { .automatic }

    func refreshModelCatalog() async throws -> [AgentModelOption] {
        availableModels()
    }

    func seedModelCatalog(_ models: [AgentModelOption]) {}

    func availableAgentModes() -> [AgentModeOption] { [] }

    func sessionBootstrapBytes(context: LaunchContext) -> Data { Data() }

    func encodeResumeSession(sessionID: String) -> Data? { nil }

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
public actor AdapterRegistry {
    public static let shared = AdapterRegistry()

    private var adapters: [AgentID: any AgentAdapter] = [:]

    public init() {}

    public func register(_ adapter: any AgentAdapter) {
        adapters[adapter.id] = adapter
    }

    public func adapter(for id: AgentID) -> (any AgentAdapter)? {
        adapters[id]
    }

    public func all() -> [any AgentAdapter] {
        Array(adapters.values).sorted { $0.displayName < $1.displayName }
    }
}
