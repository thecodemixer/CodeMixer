import Foundation

/// Subset of `.claude/settings.local.json` the executable twin must honour.
public enum ClaudeCodeTwinSettings: Sendable {

    public struct HookCommand: Sendable, Equatable {
        public var eventName: String
        public var shellCommand: String
    }

    public static func loadHookCommands(from settingsURL: URL,
                                        runtime: TwinRuntimeSeams = .live) -> [HookCommand] {
        guard let data = runtime.readDataIfPresent(at: settingsURL),
              let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let hooks = root["hooks"] as? [String: Any] else {
            return []
        }
        var out: [HookCommand] = []
        for (eventName, value) in hooks {
            for command in extractCommands(from: value) {
                out.append(HookCommand(eventName: eventName, shellCommand: command))
            }
        }
        return out
    }

    public static func settingsURL(for workspace: URL) -> URL {
        workspace.appendingPathComponent(".claude/settings.local.json")
    }

    private static func extractCommands(from value: Any) -> [String] {
        switch value {
        case let string as String:
            return [string]
        case let array as [Any]:
            return array.flatMap(extractCommands)
        case let object as [String: Any]:
            if let command = object["command"] as? String { return [command] }
            if let hooks = object["hooks"] as? [Any] {
                return hooks.compactMap { entry in
                    (entry as? [String: Any])?["command"] as? String
                }
            }
            return object.values.flatMap(extractCommands)
        default:
            return []
        }
    }
}
