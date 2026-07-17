import Foundation

import AgentCore
import AgentProtocol

/// Loads Codex picker models from the CLI's `~/.codex/models_cache.json`.
///
/// That cache is the same catalog the Codex TUI uses. There is no hardcoded
/// model list — missing or unreadable cache yields an empty catalog.
public enum CodexModelCatalog {
    /// Loads picker models from `codexHome/models_cache.json`.
    public static func load(codexHome: URL, fileSystem: any FileSystem) -> [AgentModelOption] {
        let url = codexHome.appendingPathComponent("models_cache.json", isDirectory: false)
        guard let data = try? fileSystem.readData(at: url) else { return [] }
        return parseCache(data)
    }

    /// Parses Codex `models_cache.json` into composer-facing options.
    public static func parseCache(_ data: Data) -> [AgentModelOption] {
        guard let root = try? JSONDecoder().decode(JSONValue.self, from: data),
              let models = root["models"]?.arrayValue else {
            return []
        }

        struct Ranked {
            let priority: Int
            let option: AgentModelOption
        }

        var seen: Set<String> = []
        let ranked: [Ranked] = models.compactMap { entry in
            guard let object = entry.objectValue else { return nil }
            let visibility = object["visibility"]?.stringValue ?? "list"
            guard visibility == "list" else { return nil }
            guard let code = object["slug"]?.stringValue, !code.isEmpty else { return nil }
            guard seen.insert(code).inserted else { return nil }

            let rawName = object["display_name"]?.stringValue ?? code
            let name = displayName(from: rawName)
            let efforts = thinkingEfforts(from: object["supported_reasoning_levels"])
            let defaultEffort = object["default_reasoning_level"]?.stringValue
                ?? efforts.first?.code
            let priority = object["priority"]?.intValue ?? Int.max

            return Ranked(
                priority: priority,
                option: AgentModelOption(
                    code: code,
                    name: name,
                    thinkingEffort: defaultEffort,
                    supportedThinkingEfforts: efforts
                )
            )
        }

        return ranked
            .sorted { lhs, rhs in
                if lhs.priority != rhs.priority { return lhs.priority < rhs.priority }
                return lhs.option.code < rhs.option.code
            }
            .map(\.option)
    }

    private static func thinkingEfforts(from value: JSONValue?) -> [AgentModelOption.ThinkingEffort] {
        guard let entries = value?.arrayValue else { return [] }
        var seen: Set<String> = []
        return entries.compactMap { entry in
            guard let object = entry.objectValue,
                  let code = object["effort"]?.stringValue,
                  !code.isEmpty,
                  seen.insert(code).inserted else {
                return nil
            }
            let summary = object["description"]?.stringValue ?? ""
            return AgentModelOption.ThinkingEffort(code: code, summary: summary)
        }
    }

    private static func displayName(from raw: String) -> String {
        // Codex uses "GPT-5.6-Sol"; the composer reads better with a space.
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let lastHyphen = trimmed.lastIndex(of: "-") else { return trimmed }
        let suffix = trimmed[trimmed.index(after: lastHyphen)...]
        guard suffix.count <= 12, suffix.allSatisfy(\.isLetter) else { return trimmed }
        return String(trimmed[..<lastHyphen]) + " " + suffix
    }
}

extension JSONValue {
    fileprivate var intValue: Int? {
        switch self {
        case .number(let value):
            return Int(value)
        case .string(let value):
            return Int(value)
        default:
            return nil
        }
    }
}
