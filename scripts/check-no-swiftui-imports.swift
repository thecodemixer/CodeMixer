#!/usr/bin/env swift
import Foundation

let root = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
let sources = root.appendingPathComponent("src", isDirectory: true)
let allowedFragments = [
    "/src/AgentUI/",
    "/src/CodemixerApp/",
]

let enumerator = FileManager.default.enumerator(
    at: sources,
    includingPropertiesForKeys: [.isRegularFileKey],
    options: [.skipsHiddenFiles]
)

var violations: [String] = []
while let url = enumerator?.nextObject() as? URL {
    guard url.pathExtension == "swift" else { continue }
    let path = url.path
    guard let text = try? String(contentsOf: url, encoding: .utf8),
          text.contains("import SwiftUI") else { continue }
    if !allowedFragments.contains(where: { path.contains($0) }) {
        violations.append(path.replacingOccurrences(of: root.path + "/", with: ""))
    }
}

if violations.isEmpty {
    print("OK: SwiftUI imports are confined to AgentUI and CodemixerApp.")
} else {
    print("FAIL: SwiftUI imports outside UI targets:")
    for path in violations.sorted() {
        print(" - \(path)")
    }
    exit(1)
}
