// fake-claude — PTY-aware Claude Code digital twin executable.
//
// Wire in with `CLAUDE_BIN` or `CODEMIXER_FAKE_CLAUDE=1`. Scenario selection:
// `CODEMIXER_TWIN_SCENARIO`, `--scenario=<name>`, or `CODEMIXER_TWIN_SCENARIO_FILE`.

import Foundation
import ClaudeCode

let args = CommandLine.arguments.dropFirst()
if args.first == "auth" {
    let sub = args.dropFirst().first
    if sub == "status", args.contains("--json") {
        exit(FakeClaudeLaunch.runAuthStatus())
    }
}

let workspacePath = ProcessInfo.processInfo.environment["PWD"]
    ?? FileManager.default.currentDirectoryPath
let workspace = URL(fileURLWithPath: workspacePath, isDirectory: true)
let launch = FakeClaudeLaunch.parseInteractiveArgs()
let sessionID = launch.resumeSessionID ?? ClaudeCodeTwinIdentifiers.sessionID()
let scenario = FakeClaudeLaunch.resolveScenario()

let runtime = FakeClaudeRuntime(
    workspace: workspace,
    claudeDirectory: FakeClaudeLaunch.claudeDirectory(),
    sessionID: sessionID,
    scenario: scenario,
    model: launch.model,
    permissionMode: launch.permissionMode,
    resumeSessionID: launch.resumeSessionID
)
runtime.runInteractive()
