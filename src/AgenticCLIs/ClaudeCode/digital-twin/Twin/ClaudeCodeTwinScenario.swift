import Foundation

/// Scripted turn vocabulary shared by the in-process twin and `fake-claude`.
public enum ClaudeCodeTwinScenario: Sendable, Equatable {
    case textOnly(reply: String)
    case thinkingThenReply(thinking: String, reply: String)
    case withBash(command: String, stdout: String, exitCode: Int32, reply: String)
    case withEdit(path: String, diff: String, reply: String)
    case permissionPrompt(tool: String, summary: String, reply: String)
    case needsAuth(url: URL)
    case usageOnly(inputTokens: Int, outputTokens: Int, costUSD: Double)
    case crash(partial: String)
    case workspaceTrust(workspace: String)
    case resumeLatePrompt(reply: String)
    case resumeStalled
    case swallowedEnter(reply: String)
    case sequence([ClaudeCodeTwinScenario])

    public static func named(_ name: String) -> ClaudeCodeTwinScenario? {
        switch name.lowercased() {
        case "text", "text-only": return .textOnly(reply: "Hello from the twin.")
        case "bash": return .withBash(command: "ls", stdout: "a\nb", exitCode: 0, reply: "Done.")
        case "edit": return .withEdit(path: "src/main.swift", diff: "+line", reply: "Edited.")
        case "permission": return .permissionPrompt(tool: "Bash", summary: "Run ls", reply: "ok")
        case "auth", "needs-auth": return .needsAuth(url: URL(string: "https://claude.ai/oauth/authorize?code=test")!)
        case "usage": return .usageOnly(inputTokens: 10, outputTokens: 20, costUSD: 0.001)
        case "crash": return .crash(partial: "partial…")
        case "workspace-trust": return .workspaceTrust(workspace: "/tmp/project")
        case "resume-late": return .resumeLatePrompt(reply: "Resumed.")
        case "resume-stalled": return .resumeStalled
        case "swallowed-enter": return .swallowedEnter(reply: "Recovered.")
        default: return nil
        }
    }
}
