#!/usr/bin/env swift
/// check-test-runtime.swift
///
/// Parses `swift test` output (piped on stdin) and fails if any @Suite exceeds
/// its wall-time budget.  Run like:
///
///   swift test --no-parallel 2>&1 | scripts/check-test-runtime.swift
///
/// Budgets are read from `scripts/test-runtime-overrides.json` (optional).
/// Default budget is 1.0 second per suite; individual suites can override.
///
/// Exit codes:
///   0 — all suites within budget
///   1 — one or more suites exceeded their budget
///   2 — cannot parse any timing data (stdin was empty)

import Foundation

// MARK: - Budget

let defaultBudget: Double = 1.0

struct Overrides: Codable {
    var budgets: [String: Double]
}

func budget(for suite: String) -> Double {
    let overridesURL = URL(fileURLWithPath: CommandLine.arguments[0])
        .deletingLastPathComponent()
        .deletingLastPathComponent()
        .appendingPathComponent("scripts/test-runtime-overrides.json")
    if let data = try? Data(contentsOf: overridesURL),
       let overrides = try? JSONDecoder().decode(Overrides.self, from: data),
       let custom = overrides.budgets[suite] {
        return custom
    }
    return defaultBudget
}

// MARK: - Parsing
//
// swift test emits lines like:
//   ✔ Suite "My Suite — behaviour" passed after 0.123 seconds.
//   ✘ Suite "My Suite — behaviour" failed after 4.567 seconds with 1 issue.

let suiteRE = try! NSRegularExpression(
    pattern: #"[✔✘] Suite "(.+)" (?:passed|failed) after ([0-9]+\.[0-9]+) seconds"#
)

struct SuiteResult {
    let name: String
    let elapsed: Double
}

var results: [SuiteResult] = []

while let line = readLine() {
    let ns = line as NSString
    let range = NSRange(location: 0, length: ns.length)
    if let m = suiteRE.firstMatch(in: line, range: range) {
        let name = ns.substring(with: m.range(at: 1))
        let elapsedStr = ns.substring(with: m.range(at: 2))
        if let elapsed = Double(elapsedStr) {
            results.append(SuiteResult(name: name, elapsed: elapsed))
        }
    }
}

if results.isEmpty {
    fputs("check-test-runtime: no suite timing lines found on stdin\n", stderr)
    exit(2)
}

// MARK: - Evaluation

var anyExceeded = false
for result in results.sorted(by: { $0.elapsed > $1.elapsed }) {
    let cap = budget(for: result.name)
    let marker = result.elapsed > cap ? "⚠️ OVER" : "  OK   "
    print("\(marker)  \(String(format: "%.3f", result.elapsed))s / \(String(format: "%.1f", cap))s  \(result.name)")
    if result.elapsed > cap { anyExceeded = true }
}

if anyExceeded {
    print("\nFAIL: one or more suites exceeded their wall-time budget.")
    print("Slow suites hurt feedback loops. Profile with Instruments or reduce")
    print("real-sleep calls. Add an override to scripts/test-runtime-overrides.json")
    print("only if the test genuinely can't be made faster.")
    exit(1)
} else {
    print("\nAll \(results.count) suites within budget.")
}
