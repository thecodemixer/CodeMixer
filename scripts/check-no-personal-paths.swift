#!/usr/bin/env swift
/// Fails when tracked sources or docs contain machine-specific home-directory paths.
///
/// Live probes and examples must use env vars or neutral placeholders (`/path/to/…`,
/// `$HOME/…`, `/workspace/…` fixtures) — never a real macOS home-directory path.
///
/// Usage:
///   scripts/check-no-personal-paths.swift
import Foundation

let root = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
let homeDirectoryPrefix = "/users/"

let selfRelativePath = "scripts/check-no-personal-paths.swift"

let scanRoots: [URL] = [
    root.appendingPathComponent("src", isDirectory: true),
    root.appendingPathComponent("tests", isDirectory: true),
    root.appendingPathComponent("docs", isDirectory: true),
    root.appendingPathComponent("scripts", isDirectory: true),
    root.appendingPathComponent("README.md"),
    root.appendingPathComponent("AGENTS.md"),
]

let textExtensions: Set<String> = ["swift", "md", "json", "yml", "yaml"]

func relativePath(_ url: URL) -> String {
    url.path.replacingOccurrences(of: root.path + "/", with: "")
}

func scan(file url: URL) -> [(line: Int, text: String)] {
    guard let text = try? String(contentsOf: url, encoding: .utf8) else { return [] }
    var hits: [(line: Int, text: String)] = []
    for (index, line) in text.split(separator: "\n", omittingEmptySubsequences: false).enumerated() {
        let raw = String(line)
        if raw.lowercased().contains(homeDirectoryPrefix) {
            hits.append((index + 1, raw.trimmingCharacters(in: .whitespaces)))
        }
    }
    return hits
}

var violations: [(path: String, line: Int, text: String)] = []

for scanRoot in scanRoots {
    var isDirectory: ObjCBool = false
    guard FileManager.default.fileExists(atPath: scanRoot.path, isDirectory: &isDirectory) else { continue }

    if isDirectory.boolValue {
        let enumerator = FileManager.default.enumerator(
            at: scanRoot,
            includingPropertiesForKeys: [.isRegularFileKey],
            options: [.skipsHiddenFiles]
        )
        while let url = enumerator?.nextObject() as? URL {
            guard textExtensions.contains(url.pathExtension) else { continue }
            if relativePath(url) == selfRelativePath { continue }
            for hit in scan(file: url) {
                violations.append((relativePath(url), hit.line, hit.text))
            }
        }
    } else {
        for hit in scan(file: scanRoot) {
            violations.append((relativePath(scanRoot), hit.line, hit.text))
        }
    }
}

if violations.isEmpty {
    print("OK: no machine-specific home-directory paths in tracked sources or docs.")
} else {
    print("FAIL: machine-specific paths must not be committed:")
    for violation in violations.sorted(by: { ($0.path, $0.line) < ($1.path, $1.line) }) {
        print(" - \(violation.path):\(violation.line) \(violation.text)")
    }
    exit(1)
}
