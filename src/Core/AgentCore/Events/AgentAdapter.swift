import Foundation
import AgentProtocol

/// Raw signal sources the adapter consumes. The engine populates the streams
/// the adapter declared via its capabilities; everything else is `nil`.
public struct AgentInputs: Sendable {
    public let ptyOutput: AsyncStream<Data>
    public let screen: any TerminalSnapshotting
    public let hookSocket: HookSocketHandle?
    public let workspace: URL
    public let resumeSessionID: String?
    public let sessionID: AsyncStream<String>

    public init(ptyOutput: AsyncStream<Data>,
                screen: any TerminalSnapshotting,
                hookSocket: HookSocketHandle?,
                workspace: URL,
                resumeSessionID: String? = nil,
                sessionID: AsyncStream<String>) {
        self.ptyOutput = ptyOutput
        self.screen = screen
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

    /// Current cursor row (0-indexed).
    func cursorRow() async -> Int
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

    // MARK: Authentication

    func authStatus(env: ResolvedEnvironment) async -> AuthStatus
    /// Regex used to lift "open this URL to log in" prompts out of PTY bytes.
    /// Return nil if the adapter never emits such URLs.
    func authURLPattern() -> NSRegularExpression?
    /// Argv to inject after spawn to start a login flow (e.g. `["/login"]`).
    func loginCommandArgv() -> [String]?

    // MARK: Capability declaration

    var capabilities: AgentCapabilities { get }

    // MARK: Event stream

    func makeEventStream(inputs: AgentInputs) -> AsyncStream<AgentEvent>

    // MARK: Input encoding

    func encodeUserPrompt(_ text: String) -> Data
    func cancelSequence() -> Data

    // MARK: Permission responses

    func encodePermissionResponse(_ decision: PermissionDecision,
                                  for prompt: PermissionPrompt) -> PermissionResponseDelivery

    // MARK: Slash commands

    var slashCommandCatalog: [SlashCommand] { get }
    func enumerateProjectCommands(workspace: URL) async -> [SlashCommand]

    // MARK: Sessions

    func listResumableSessions(workspace: URL) async -> [SessionSummary]
    func resumeArgvAddition(sessionID: String) -> [String]

    // MARK: Tool rendering

    func toolRenderHint(toolName: String, input: ToolInput) -> ToolRenderHint

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
