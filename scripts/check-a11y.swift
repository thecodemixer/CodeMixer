#!/usr/bin/env swift
import Foundation

// check-a11y.swift — accessibility audit for icon-only SwiftUI controls.
//
// Fails if any line containing `Image(systemName:)` lacks an
// `.accessibilityLabel(`, `.accessibilityHidden(`, or `.help(` within a small
// window around the call.
//
// Usage:
//   scripts/check-a11y.swift
//   scripts/check-a11y.swift <SourcesDirectory>

let fm = FileManager.default

let scriptURL = URL(fileURLWithPath: CommandLine.arguments[0]).resolvingSymlinksInPath()
let defaultSources = scriptURL
    .deletingLastPathComponent()
    .deletingLastPathComponent()
    .appendingPathComponent("src/AgentUI", isDirectory: true)
let sourcesRoot = CommandLine.arguments.count > 1
    ? URL(fileURLWithPath: CommandLine.arguments[1])
    : defaultSources

print("Auditing \(sourcesRoot.path) for icon-only controls without accessibilityLabel…")

guard let enumerator = fm.enumerator(at: sourcesRoot,
                                     includingPropertiesForKeys: [.isRegularFileKey]) else {
    FileHandle.standardError.write(Data("cannot enumerate \(sourcesRoot.path)\n".utf8))
    exit(2)
}

let trigger = "Image(systemName:"
let allowMarkers = ["accessibilityLabel", "accessibilityHidden", ".help("]
let windowBefore = 4
let windowAfter = 8

struct Violation { let file: String; let line: Int }
var violations: [Violation] = []

for case let url as URL in enumerator where url.pathExtension == "swift" {
    let path = url.path
    if path.contains("/Build/") { continue }
    guard let source = try? String(contentsOf: url, encoding: .utf8) else { continue }
    let lines = source.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
    for (idx, line) in lines.enumerated() where line.contains(trigger) {
        let lower = max(0, idx - windowBefore)
        let upper = min(lines.count, idx + windowAfter + 1)
        let context = lines[lower..<upper].joined(separator: "\n")
        if !allowMarkers.contains(where: { context.contains($0) }) {
            print("  WARN  \(path):\(idx + 1)  — Image(systemName:) without accessibilityLabel nearby")
            violations.append(Violation(file: path, line: idx + 1))
        }
    }
}

if violations.isEmpty {
    print("No accessibility violations found.")
    exit(0)
}
print("")
print("Found \(violations.count) potential accessibility violation(s).")
print("Add .accessibilityLabel(\"…\") to every icon-only interactive element.")
exit(1)
