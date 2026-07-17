import Foundation
import AgentProtocol

/// Canonical `AgentCommand` samples shared across wire and remote parity tests.
public enum AgentCommandFixtures {

    /// Stable UUIDs so remote dispatch parity assertions stay deterministic.
    public enum IDs {
        public static let bubble = UUID(uuidString: "00000000-0000-0000-0000-000000000001")!
        public static let permission = UUID(uuidString: "00000000-0000-0000-0000-000000000002")!
        public static let hunk = UUID(uuidString: "00000000-0000-0000-0000-000000000003")!
        public static let clientAction = UUID(uuidString: "00000000-0000-0000-0000-000000000004")!
    }

    public static let sampleAttachment = AttachmentRef(id: "upload-1",
                                                       filename: "spec.md",
                                                       byteCount: 10,
                                                       mimeType: "text/markdown")

    /// One representative value per `AgentCommand` case.
    public static func dispatchParitySamples() -> [AgentCommand] {
        [
            .sendPrompt(text: "hello", attachments: [sampleAttachment]),
            .cancelCurrentTurn,
            .editAndResubmitLast(targetBubbleID: IDs.bubble, text: "edited", attachments: []),
            .newSession,
            .compact,
            .selectModel(id: "claude-sonnet-4-5"),
            .setPermissionMode(.default),
            .toggleThinkMode(enabled: true),
            .toggleReviewMode(enabled: false),
            .runSlashCommand(name: "/review", args: ["quick"]),
            .runCustomCommand(path: ".claude/commands/release.md", args: ["v1"]),
            .respondToPermission(id: IDs.permission, decision: .allow),
            .openProject(path: "/tmp/project", resumeSessionID: "session-1"),
            .closeSession,
            .speakAssistantBubble(eventID: IDs.bubble, action: .play),
            .revertFile(path: "Sources/App.swift"),
            .revertHunk(path: "Sources/App.swift", hunkID: IDs.hunk),
            .updateAutoApprovalRules([AutoApprovalRule(match: "Bash ls *", decision: .allow)]),
            .updateAppearancePref(key: .theme, value: .string("dark")),
            .requestSnapshot(.conversation),
            .recordClientAction(ClientAction(
                id: IDs.clientAction,
                kind: .permissionMode,
                title: "Permission mode",
                detail: "Plan"
            )),
        ]
    }

    /// Extra variants for wire JSON round-trip coverage beyond `dispatchParitySamples()`.
    public static func wireRoundTripExtras(bubbleID: UUID, permissionID: UUID) -> [AgentCommand] {
        [
            .setPermissionMode(.acceptEdits),
            .toggleThinkMode(enabled: false),
            .toggleReviewMode(enabled: true),
            .runSlashCommand(name: "/review", args: []),
            .runCustomCommand(path: "/proj/review.md", args: ["arg1", "arg2"]),
            .respondToPermission(id: permissionID, decision: .allowAlways),
            .respondToPermission(id: permissionID, decision: .deny),
            .openProject(path: "/repo", resumeSessionID: nil),
            .speakAssistantBubble(eventID: bubbleID, action: .pause),
            .speakAssistantBubble(eventID: bubbleID, action: .stop),
            .revertFile(path: "src/foo.swift"),
            .revertHunk(path: "src/foo.swift", hunkID: bubbleID),
            .updateAutoApprovalRules([
                AutoApprovalRule(match: "Bash ls *", decision: .allow),
                AutoApprovalRule(match: "Bash rm *", decision: .deny),
            ]),
            .updateAppearancePref(key: .reduceMotion, value: .bool(true)),
            .updateAppearancePref(key: .fontSizeScale, value: .double(1.25)),
            .requestSnapshot(.diff),
            .requestSnapshot(.sessions),
            .requestSnapshot(.prefs),
        ]
    }
}
