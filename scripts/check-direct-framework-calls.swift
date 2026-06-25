#!/usr/bin/env swift
import Foundation

// Fails if business code calls Apple frameworks directly instead of going
// through the External/ wrapper. Wrappers themselves and the C shim are
// exempt. See docs/style/code-style.md §18.5 for the rationale.
//
// Usage:
//   scripts/check-direct-framework-calls.swift
//   scripts/check-direct-framework-calls.swift <SourcesDirectory>

let fm = FileManager.default

// Patterns are narrow on purpose: instantiation / API call shapes, so that
// bare type references in doc-comments don't trigger the lint. Add new
// patterns when introducing a new wrapper (see code-style.md §18.5).
let patterns: [String] = [
    #"Foundation\.Process|Process\(\)"#,
    #"SecItemAdd|SecItemCopyMatching|SecItemDelete|SecItemUpdate"#,
    #"FSEventStreamCreate|FSEventStreamStart|FSEventStreamStop|FSEventStreamInvalidate|FSEventStreamRelease|FSEventStreamSetDispatchQueue"#,
    #"NWListener\(|NWConnection\("#,
    #"AVSpeechSynthesizer\(|AVAudioEngine\("#,
    #"SFSpeechRecognizer\(|SFSpeechAudioBufferRecognitionRequest\("#,
    #"UNUserNotificationCenter\.current\(\)"#,
    #"NetService\("#,
    #"URLSession\.shared|URLSession\("#,
]

// Path fragments that mark a file as an allowed wrapper site.
let exemptFragments: [String] = [
    "/External/",
    "/CPosixBridge/",
    "/Network/LiveNetworkTransport.swift",
    "/Network/InMemoryNetworkTransport.swift",
]

let scriptURL = URL(fileURLWithPath: CommandLine.arguments[0]).resolvingSymlinksInPath()
let defaultSources = scriptURL
    .deletingLastPathComponent()
    .deletingLastPathComponent()
    .appendingPathComponent("src", isDirectory: true)
let sourcesRoot = CommandLine.arguments.count > 1
    ? URL(fileURLWithPath: CommandLine.arguments[1])
    : defaultSources

guard let enumerator = fm.enumerator(at: sourcesRoot,
                                     includingPropertiesForKeys: [.isRegularFileKey]) else {
    FileHandle.standardError.write(Data("cannot enumerate \(sourcesRoot.path)\n".utf8))
    exit(2)
}

struct Hit { let file: String; let line: Int; let text: String; let pattern: String }
var hits: [Hit] = []
let compiled: [(String, NSRegularExpression)] = patterns.compactMap { p in
    guard let rx = try? NSRegularExpression(pattern: p) else { return nil }
    return (p, rx)
}

for case let url as URL in enumerator where url.pathExtension == "swift" {
    let path = url.path
    if exemptFragments.contains(where: { path.contains($0) }) { continue }
    guard let source = try? String(contentsOf: url, encoding: .utf8) else { continue }
    for (idx, line) in source.split(separator: "\n", omittingEmptySubsequences: false).enumerated() {
        let asString = String(line)
        // Skip pure-comment lines: bare type references inside doc-comments
        // are not API calls and would generate noise.
        let trimmed = asString.trimmingCharacters(in: .whitespaces)
        if trimmed.hasPrefix("//") || trimmed.hasPrefix("*") || trimmed.hasPrefix("///") {
            continue
        }
        let range = NSRange(asString.startIndex..., in: asString)
        for (pattern, rx) in compiled where rx.firstMatch(in: asString, range: range) != nil {
            hits.append(Hit(file: path, line: idx + 1, text: asString, pattern: pattern))
        }
    }
}

if hits.isEmpty {
    print("No direct framework calls outside wrappers.")
    exit(0)
}

print("Direct framework calls found (forbidden outside External/):")
for hit in hits {
    print("  \(hit.file):\(hit.line): \(hit.text.trimmingCharacters(in: .whitespaces))")
    print("    pattern: \(hit.pattern)")
}
print("")
print("\(hits.count) forbidden direct framework call(s) found.")
print("See docs/style/code-style.md §18.5 for the wrapper strategy.")
exit(1)
