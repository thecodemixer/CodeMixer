import Foundation

import AgentCore
import AgentProtocol

/// Discovers Claude Code picker models via print-mode `/model` (and efforts
/// via `/effort`).
///
/// Print mode can consume agent credits, so callers must cache the result at
/// the workspace level and only re-run on an explicit user refresh.
public enum ClaudeModelCatalog {
    public static let manualRefreshDetail =
        "Uses Claude Code print mode (`claude -p`). Refresh sparingly — it can consume agent credits."

    /// Runs `claude -p '/model'` (+ `/effort`) and builds picker options.
    public static func discover(executable: URL,
                                env: ResolvedEnvironment,
                                processRunner: ProcessRunner) async throws -> [AgentModelOption] {
        let modelText = try await printCommand(
            "/model",
            executable: executable,
            env: env,
            processRunner: processRunner
        )
        let effortText = (try? await printCommand(
            "/effort",
            executable: executable,
            env: env,
            processRunner: processRunner
        )) ?? ""
        let efforts = parseEffortOutput(effortText)
        return parsePrintModelOutput(modelText, thinkingEfforts: efforts)
    }

    /// Parses the human-readable `/model` print result (or the `result` field
    /// of `--output-format json`).
    public static func parsePrintModelOutput(_ raw: String,
                                             thinkingEfforts: [AgentModelOption.ThinkingEffort] = [])
        -> [AgentModelOption] {
        let text = resultText(from: raw)
        guard let available = availableList(from: text) else { return [] }
        var seen: Set<String> = []
        return available.compactMap { token -> AgentModelOption? in
            let code = token.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !code.isEmpty, seen.insert(code).inserted else { return nil }
            return AgentModelOption(
                code: code,
                name: displayName(for: code),
                thinkingEffort: thinkingEfforts.first(where: { $0.code == "medium" })?.code
                    ?? thinkingEfforts.first?.code,
                supportedThinkingEfforts: thinkingEfforts
            )
        }
    }

    /// Parses `Usage: /effort <low|medium|high|…>`.
    public static func parseEffortOutput(_ raw: String) -> [AgentModelOption.ThinkingEffort] {
        let text = resultText(from: raw)
        guard let open = text.firstIndex(of: "<"),
              let close = text[open...].firstIndex(of: ">") else {
            return []
        }
        let body = text[text.index(after: open)..<close]
        var seen: Set<String> = []
        return body.split(separator: "|").compactMap { part in
            let code = part.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !code.isEmpty, code != "auto", seen.insert(code).inserted else { return nil }
            return AgentModelOption.ThinkingEffort(code: code, summary: "")
        }
    }

    // MARK: - Private

    private static func printCommand(_ prompt: String,
                                     executable: URL,
                                     env: ResolvedEnvironment,
                                     processRunner: ProcessRunner) async throws -> String {
        let result = try await processRunner.run(
            executable: executable,
            arguments: ["-p", prompt, "--output-format", "json"],
            env: env.variables
        )
        return String(decoding: result.stdout, as: UTF8.self)
    }

    private static func resultText(from raw: String) -> String {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        struct Envelope: Decodable { let result: String? }
        if let data = trimmed.data(using: .utf8),
           let envelope = try? JSONDecoder().decode(Envelope.self, from: data),
           let result = envelope.result {
            return result
        }
        return trimmed
    }

    private static func availableList(from text: String) -> [String]? {
        let marker = "Available:"
        guard let range = text.range(of: marker, options: .caseInsensitive) else { return nil }
        var list = String(text[range.upperBound...])
        if let orRange = list.range(of: ", or a full model ID", options: .caseInsensitive) {
            list = String(list[..<orRange.lowerBound])
        } else if let period = list.firstIndex(of: ".") {
            list = String(list[..<period])
        }
        return list
            .split(separator: ",")
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
    }

    private static func displayName(for code: String) -> String {
        if code.hasSuffix("[1m]") {
            let base = String(code.dropLast(4))
            return "\(titleCaseAlias(base)) (1M)"
        }
        return titleCaseAlias(code)
    }

    private static func titleCaseAlias(_ code: String) -> String {
        switch code.lowercased() {
        case "sonnet": return "Sonnet"
        case "opus": return "Opus"
        case "haiku": return "Haiku"
        case "fable": return "Fable"
        case "best": return "Best"
        case "default": return "Default"
        case "opusplan": return "Opus Plan"
        default:
            return code
                .split(separator: "-")
                .map { part in
                    let s = String(part)
                    return s.prefix(1).uppercased() + s.dropFirst()
                }
                .joined(separator: " ")
        }
    }
}
