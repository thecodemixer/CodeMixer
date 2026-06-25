import Foundation

/// The complete, typed input alphabet of the agent engine.
///
/// Every UI affordance — keyboard, mouse, voice, remote — maps to exactly one
/// case here. New cases gate remote support behind the same protocol; a
/// `tests-remote-parity` suite enforces that every case has both a UI
/// affordance and a wire decoder.
public enum AgentCommand: Sendable, Codable, Hashable {

    // MARK: Conversation

    case sendPrompt(text: String, attachments: [AttachmentRef])
    case cancelCurrentTurn
    case editAndResubmitLast(targetBubbleID: UUID, text: String, attachments: [AttachmentRef])

    // MARK: Slash commands (typed, not stringified)

    case newSession                                    // /clear
    case compact                                       // /compact
    case selectModel(id: String)                       // /model
    case setPermissionMode(PermissionMode)
    case toggleThinkMode(enabled: Bool)                // /think
    case toggleReviewMode(enabled: Bool)               // /review
    case runSlashCommand(name: String, args: [String])
    case runCustomCommand(path: String, args: [String])

    // MARK: Permission prompts

    case respondToPermission(id: UUID, decision: PermissionDecision)
    case respondToInlinePrompt(id: UUID, text: String)

    // MARK: Session lifecycle

    case openProject(path: String, resumeSessionID: String?)
    case closeSession

    // MARK: Voice & TTS (local-only intent)

    case speakAssistantBubble(eventID: UUID, action: TTSAction)

    // MARK: Diff panel

    case revertFile(path: String)
    case revertHunk(path: String, hunkID: UUID)

    // MARK: Settings (atomic — all clients see the update)

    case updateAutoApprovalRules([AutoApprovalRule])
    case updateAppearancePref(key: AppearancePrefKey, value: AppearancePrefValue)

    // MARK: Diagnostics

    case requestSnapshot(SnapshotKind)
}

/// Shared inbound entry point for the agent engine.
///
/// Implemented by `AgentEngine` itself (in `AgentCore`) and by any test double
/// (in `AgentTestSupport`). SwiftUI views call it directly; the remote server
/// decodes wire frames into `AgentCommand` and calls it. There is no second
/// code path.
public protocol AgentEngineCommandPort: Sendable {
    func send(_ command: AgentCommand) async throws
}
