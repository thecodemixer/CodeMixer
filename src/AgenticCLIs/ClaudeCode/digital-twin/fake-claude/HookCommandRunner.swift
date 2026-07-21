import Foundation
import AgentCore
import ClaudeCode

/// Runs hook commands from `.claude/settings.local.json`.
struct HookCommandRunner {
    private let workspace: URL
    private let processRunner = TwinProcessRunner()
    private let commands: [ClaudeCodeTwinSettings.HookCommand]

    init(workspace: URL) {
        self.workspace = workspace
        self.commands = ClaudeCodeTwinSettings.loadHookCommands(
            from: Self.settingsURL(for: workspace)
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

    private static func settingsURL(for workspace: URL) -> URL {
        let candidates = workspaceVariants(for: workspace)
            .map(ClaudeCodeTwinSettings.settingsURL(for:))
        return candidates.first { FileManager.default.fileExists(atPath: $0.path) }
            ?? ClaudeCodeTwinSettings.settingsURL(for: workspace)
    }

    private static func workspaceVariants(for workspace: URL) -> [URL] {
        let candidates = [
            workspace,
            workspace.resolvingSymlinksInPath(),
            privateVarAlias(for: workspace),
            logicalVarAlias(for: workspace),
        ].compactMap { $0 }

        var seen: Set<String> = []
        return candidates.filter { seen.insert($0.path).inserted }
    }

    private static func privateVarAlias(for workspace: URL) -> URL? {
        let path = workspace.path
        guard path.hasPrefix("/var/") else { return nil }
        return URL(fileURLWithPath: SystemPaths.privatePrefix + path, isDirectory: true)
    }

    private static func logicalVarAlias(for workspace: URL) -> URL? {
        let path = workspace.path
        guard path.hasPrefix(SystemPaths.privatePrefix + "/var/") else { return nil }
        return URL(fileURLWithPath: String(path.dropFirst(SystemPaths.privatePrefix.count)), isDirectory: true)
    }
}
