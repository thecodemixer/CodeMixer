import Foundation
import AgentProtocol

/// Parses `cursor-agent models` output into composer-facing model options.
///
/// Cursor ACP often reports an empty `models.availableModels` list. The CLI
/// model command is the practical fallback for the shipping Cursor adapter.
enum CursorModelCatalog {
    static func parse(_ data: Data) -> [AgentModelOption] {
        guard let raw = String(data: data, encoding: .utf8) else { return [] }
        return parse(raw)
    }

    static func parse(_ raw: String) -> [AgentModelOption] {
        var seen: Set<String> = []
        return strippedANSIEscapes(from: raw)
            .split(separator: "\n", omittingEmptySubsequences: true)
            .compactMap { line -> AgentModelOption? in
                let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
                guard let separator = trimmed.range(of: " - ") else { return nil }
                let id = String(trimmed[..<separator.lowerBound])
                    .trimmingCharacters(in: .whitespacesAndNewlines)
                guard !id.isEmpty, seen.insert(id).inserted else { return nil }
                let label = displayLabel(
                    from: String(trimmed[separator.upperBound...])
                )
                return AgentModelOption(id: id, label: label.isEmpty ? id : label)
            }
    }

    private static func displayLabel(from raw: String) -> String {
        var label = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        for marker in ["(default)", "(current)"] {
            label = label.replacingOccurrences(of: marker, with: "")
        }
        return label.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private static func strippedANSIEscapes(from raw: String) -> String {
        raw.replacingOccurrences(
            of: #"\u{001B}\[[0-?]*[ -/]*[@-~]"#,
            with: "",
            options: .regularExpression
        )
    }
}
