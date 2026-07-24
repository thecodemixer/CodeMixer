import Foundation

/// Testable inventory of `AgentCommand` cases that have a Mac UI producer.
///
/// This is intentionally boring: SwiftUI views own the actual buttons/menus,
/// while this manifest gives CI one stable place to detect command-surface
/// drift. When adding an `AgentCommand`, update this file in the same change
/// that wires the corresponding UI affordance or documents why it is remote-only.
public enum InteractionCoverage {

    public enum CommandShape: String, CaseIterable, Sendable, Hashable {
        case sendPrompt
        case cancelCurrentTurn
        case editAndResubmitLast
        case newSession
        case compact
        case selectModel
        case setPermissionMode
        case setAgentMode
        case runSlashCommand
        case respondToPermission
        case openProject
        case closeSession
        case speakAssistantBubble
        case revertFile
        case revertHunk
        case updateAutoApprovalRules
        case updateAppearancePref
        case requestSnapshot
        case recordClientAction
    }

    public static let macUI: Set<CommandShape> = [
        .sendPrompt,
        .cancelCurrentTurn,
        .editAndResubmitLast,
        .newSession,
        .compact,
        .selectModel,
        .setPermissionMode,
        .setAgentMode,
        .runSlashCommand,
        .respondToPermission,
        .openProject,
        .closeSession,
        .speakAssistantBubble,
        .revertFile,
        .revertHunk,
        .updateAutoApprovalRules,
        .updateAppearancePref,
        .requestSnapshot,
        .recordClientAction,
    ]

    public static let remoteOnly: Set<CommandShape> = []
}
