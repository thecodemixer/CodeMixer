#!/usr/bin/env swift
import Foundation

// Manual live-characterization helper for Claude Code. Not run in CI.
// Captures hook JSON and transcript snippets into sanitized fixture files.
//
// Prerequisites: logged-in `claude`, `jq` optional for pretty-print.
// Usage:
//   scripts/characterize-claude-code.swift --workspace /path/to/project --scenario text

struct Options {
    var workspace: URL
    var scenario: String
    var outputDir: URL
}

func parseArgs() -> Options? {
    var workspace: URL?
    var scenario = "text"
    var outputDir = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
        .appendingPathComponent("tests/AgenticCLIs/ClaudeCode/ClaudeAdapterTests/Fixtures/live", isDirectory: true)
    var args = Array(CommandLine.arguments.dropFirst())
    while !args.isEmpty {
        switch args.removeFirst() {
        case "--workspace" where !args.isEmpty:
            workspace = URL(fileURLWithPath: args.removeFirst())
        case "--scenario" where !args.isEmpty:
            scenario = args.removeFirst()
        case "--output" where !args.isEmpty:
            outputDir = URL(fileURLWithPath: args.removeFirst(), isDirectory: true)
        default:
            break
        }
    }
    guard let workspace else {
        FileHandle.standardError.write(Data("usage: characterize-claude-code.swift --workspace <path> [--scenario text]\n".utf8))
        return nil
    }
    return Options(workspace: workspace, scenario: scenario, outputDir: outputDir)
}

guard let opts = parseArgs() else { exit(2) }

try FileManager.default.createDirectory(at: opts.outputDir, withIntermediateDirectories: true)

let manifest: [String: Any] = [
    "captured_at": ISO8601DateFormatter().string(from: Date()),
    "scenario": opts.scenario,
    "workspace": opts.workspace.path,
    "claude_version": "pending — run `claude --version` manually",
    "redaction": "manual review required",
]
let manifestData = try JSONSerialization.data(withJSONObject: manifest, options: [.prettyPrinted, .sortedKeys])
try manifestData.write(to: opts.outputDir.appendingPathComponent("manifest.json"))

print("Wrote characterization manifest to \(opts.outputDir.path)")
print("Next: run Codemixer with hooks enabled, copy sanitized hook/transcript samples into this directory.")
