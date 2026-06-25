#!/usr/bin/env swift
/// regen-coverage-manifest.swift
///
/// Scans every `.swift` file under `src/` and emits a sorted list of
/// `public` type, function, and property declarations.  The list is diffed
/// against the checked-in `tests/Core/AgentCoreTests/CoverageManifest.swift`
/// comment-block that begins with `// MANIFEST_SYMBOLS_BEGIN` and ends with
/// `// MANIFEST_SYMBOLS_END`.
///
/// Usage:
///   scripts/regen-coverage-manifest.swift [--check]
///
/// Without `--check` the script prints the freshly scanned symbol list.
/// With `--check` it exits non-zero if the scanned list differs from the
/// manifest, making CI fail on untracked API drift.

import Foundation

// MARK: - Helpers

enum ScriptPaths {
    static let env = "/usr/bin/env"
}

func run(_ args: [String]) -> String {
    let task = Process()
    task.executableURL = URL(fileURLWithPath: ScriptPaths.env)
    task.arguments = args
    let pipe = Pipe()
    task.standardOutput = pipe
    task.standardError = Pipe()
    try? task.run()
    task.waitUntilExit()
    return String(data: pipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
}

// MARK: - Public symbol extraction

/// Regex that matches the first `public` declaration on a line, returning the
/// identifier immediately following the access modifier + keyword.
let declarationRE = try! NSRegularExpression(
    pattern: #"^\s*public\s+(?:(?:final|open|lazy|weak|static|class|nonisolated|override|mutating|nonmutating|dynamic|required)\s+)*(?:func|var|let|struct|class|actor|enum|typealias|init|subscript|protocol)\s+(\w+)"#
)

func extractSymbols(from text: String) -> [String] {
    var out: [String] = []
    let lines = text.components(separatedBy: "\n")
    for line in lines {
        let ns = line as NSString
        let range = NSRange(location: 0, length: ns.length)
        if let m = declarationRE.firstMatch(in: line, range: range) {
            let nameRange = m.range(at: 1)
            if nameRange.location != NSNotFound {
                out.append(ns.substring(with: nameRange))
            }
        }
    }
    return out
}

// MARK: - Discovery

let repoRoot: URL = {
    let script = URL(fileURLWithPath: CommandLine.arguments[0])
    // script lives at <root>/scripts/regen-coverage-manifest.swift
    return script.deletingLastPathComponent().deletingLastPathComponent()
}()

let sourcesRoot = repoRoot
    .appendingPathComponent("src", isDirectory: true)

func swiftFiles(under dir: URL) -> [URL] {
    guard let enumerator = FileManager.default.enumerator(
        at: dir,
        includingPropertiesForKeys: [.isRegularFileKey],
        options: [.skipsHiddenFiles]
    ) else { return [] }
    return enumerator.compactMap { $0 as? URL }
        .filter { $0.pathExtension == "swift" }
        .sorted { $0.path < $1.path }
}

var symbols: [String] = []
for file in swiftFiles(under: sourcesRoot) {
    let text = (try? String(contentsOf: file, encoding: .utf8)) ?? ""
    symbols.append(contentsOf: extractSymbols(from: text))
}

let unique = Array(Set(symbols)).sorted()

// MARK: - Check mode

let checkMode = CommandLine.arguments.contains("--check")

let manifestPath = repoRoot
    .appendingPathComponent("tests/Core/AgentCoreTests/CoverageManifest.swift")

if checkMode {
    guard let manifestText = try? String(contentsOf: manifestPath, encoding: .utf8) else {
        print("error: cannot read \(manifestPath.path)")
        exit(1)
    }

    // Parse the symbols embedded in the manifest's MANIFEST_SYMBOLS block.
    var manifestSymbols: [String] = []
    var inside = false
    for line in manifestText.components(separatedBy: "\n") {
        if line.contains("MANIFEST_SYMBOLS_BEGIN") { inside = true; continue }
        if line.contains("MANIFEST_SYMBOLS_END") { inside = false; continue }
        if inside {
            let s = line.trimmingCharacters(in: .whitespaces).trimmingCharacters(in: CharacterSet(charactersIn: "// "))
            if !s.isEmpty { manifestSymbols.append(s) }
        }
    }

    let added   = Set(unique).subtracting(Set(manifestSymbols))
    let removed = Set(manifestSymbols).subtracting(Set(unique))

    if added.isEmpty && removed.isEmpty {
        print("Coverage manifest is up-to-date (\(unique.count) symbols).")
        exit(0)
    }

    if !added.isEmpty {
        print("NEW public symbols not in manifest (add them + a test):")
        added.sorted().forEach { print("  + \($0)") }
    }
    if !removed.isEmpty {
        print("Symbols in manifest but no longer public (remove or rename):")
        removed.sorted().forEach { print("  - \($0)") }
    }
    exit(1)
} else {
    // Print mode: output the block to paste into the manifest.
    print("// MANIFEST_SYMBOLS_BEGIN")
    unique.forEach { print("// \($0)") }
    print("// MANIFEST_SYMBOLS_END")
    print("\n// Total: \(unique.count) unique public symbols")
}
