import Foundation
import ClaudeCode

/// Runs hook commands from `.claude/settings.local.json`.
struct HookCommandRunner {
    private let workspace: URL
    private let processRunner = TwinProcessRunner()
    private let commands: [ClaudeCodeTwinSettings.HookCommand]

    init(workspace: URL) {
        self.workspace = workspace
        self.commands = ClaudeCodeTwinSettings.loadHookCommands(
            from: ClaudeCodeTwinSettings.settingsURL(for: workspace)
        )
    }

    func emit(eventName: String, payload: Data) {
        let matching = commands.filter { $0.eventName == eventName }
        guard !matching.isEmpty else { return }
        for hook in matching {
            _ = try? processRunner.run(shellCommand: hook.shellCommand,
                                         stdin: payload,
                                         cwd: workspace)
        }
    }
}
