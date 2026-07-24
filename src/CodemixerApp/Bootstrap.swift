import SwiftUI
import AppKit
import AgentCore
import AgentUI
import AgentProtocol
import AgentRemoteControl

/// Which command port backs the running GUI: an in-process `AgentEngine`
/// (Mode A) or a `RemoteEngineClient` talking to `codemixerd` (Mode B). See
/// `docs/architecture.md` §4.1.
enum EngineBackend {
    case inProcess(AgentEngine)
    case remote(RemoteEngineClient)

    var bus: MulticastEventBus {
        switch self {
        case .inProcess(let engine):
            return engine.bus
        case .remote(let client):
            return client.bus
        }
    }
}

/// GUI-only app-lifecycle owner: engine bootstrap, workspace open/close, and
/// remote-control wiring. Split across extensions by concern —
/// engine/adapter registration and app-event bridging in `Bootstrap+Engine`,
/// workspace picker/open/close in `Bootstrap+Workspace`, remote pairing and
/// LaunchAgent control in `Bootstrap+Remote`, session export in
/// `Bootstrap+SessionExport`.
@MainActor
@Observable
final class Bootstrap {
    var viewModel: EngineViewModel?
    var workspace: URL?
    var remoteFingerprint: String?
    var remoteHost: RemoteControlServer.BindHost = .loopback
    var showProjectPicker: Bool = false
    var showOpenProject: Bool = false
    var showNewProjectSheet: Bool = false
    var showNewWorkspaceSheet: Bool = false
    var showDebugTerminal: Bool = false
    var showEventLog: Bool = false
    var showSilentDiagnostics: Bool = false
    var startupError: String?
    /// False until `start()` finishes engine bootstrap and optional workspace restore.
    var isStartupComplete = false
    /// True while opening a workspace and waiting for model catalogs to load.
    /// The main workspace UI stays hidden until this clears.
    var isPreparingWorkspace = false
    /// Configure Project sheet while type is still unknown (Add Existing or Open Workspace).
    var pendingConfigure: PendingConfigure?

    let voice = VoiceInputService()
    let tts = TTSService()
    let notifications = UserNotificationBridge()

    var engineBackend: EngineBackend?
    var engine: AgentEngine? {
        guard case .inProcess(let engine) = engineBackend else { return nil }
        return engine
    }

    /// Mode B only: loopback `RemoteEngineClient` that implements
    /// `AgentEngineCommandPort` for `EngineViewModel`. Not the server's
    /// connected-peer count — see `EngineViewModel.connectedRemoteClients`.
    var remoteClient: RemoteEngineClient? {
        guard case .remote(let client) = engineBackend else { return nil }
        return client
    }

    var remoteRuntime: RemoteRuntimeCoordinator?
    var pairing: PairingService?
    var appEventTask: Task<Void, Never>?
    let launchAgentInstaller = LaunchAgentInstaller()

    /// Shared create/open workspace paths (model-catalog warm included).
    var workspaceLifecycle: WorkspaceLifecycle? {
        viewModel.map { WorkspaceLifecycle(model: $0) }
    }

    var bus: MulticastEventBus? { engineBackend?.bus }

    var debugTerminalSnapshotText: (@Sendable () async -> String)? {
        guard let engine else { return nil }
        return { await engine.terminalSnapshotText() }
    }
}

/// Waiting on Configure Project before Add Existing registration or Open Workspace adopt.
enum PendingConfigure: Hashable {
    /// Register `draft.existingFolderURL` into the open workspace after type is chosen.
    case addExisting(ProjectDraft)
    /// Adopt the folder as the workspace root after type is chosen.
    case openWorkspace(ProjectDraft, resumeSessionID: String?)

    var draft: ProjectDraft {
        switch self {
        case .addExisting(let draft), .openWorkspace(let draft, _):
            return draft
        }
    }

    var folderURL: URL? { draft.existingFolderURL }
}
