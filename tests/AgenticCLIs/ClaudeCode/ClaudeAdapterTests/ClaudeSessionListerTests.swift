import Foundation
import Testing
@testable import ClaudeCode
import AgentCore
import AgentTestSupport

@Suite("ClaudeSessionLister")
struct ClaudeSessionListerTests {

  @Test("lastActivity uses the newest transcript timestamp, not file mtime")
  func lastActivityUsesTranscriptTimestamp() {
    let old = Date(timeIntervalSince1970: 1_700_000_000)
    let recent = Date(timeIntervalSince1970: 1_800_000_000)
    let line = """
    {"type":"user","uuid":"u1","timestamp":"\(iso(old))","message":{"role":"user","content":"old"}}
    {"type":"assistant","uuid":"a1","timestamp":"\(iso(recent))","message":{"role":"assistant","content":[{"type":"text","text":"reply"}]}}
    """
    let data = Data(line.utf8)
    let fallback = Date()

    let activity = ClaudeSessionLister.lastActivity(in: data, fallback: fallback)
    #expect(activity == recent)
    #expect(activity != fallback)
  }

  @Test("summaries order sessions by transcript activity")
  func summariesOrderByTranscriptActivity() throws {
    let fs = InMemoryFileSystem()
    let workspace = URL(fileURLWithPath: "/tmp/ws")
    let claude = URL(fileURLWithPath: "/tmp/claude")
    let projects = ClaudeProjectPaths.projectDirectory(for: workspace, claudeDirectory: claude)
    try fs.createDirectory(at: projects, withIntermediates: true)

    let older = Date(timeIntervalSince1970: 1_700_000_000)
    let newer = Date(timeIntervalSince1970: 1_800_000_000)
    try fs.writeAtomically(
      Data("{\"type\":\"user\",\"uuid\":\"u\",\"timestamp\":\"\(iso(older))\",\"message\":{\"role\":\"user\",\"content\":\"older\"}}".utf8),
      to: projects.appendingPathComponent("older.jsonl"))
    try fs.writeAtomically(
      Data("{\"type\":\"user\",\"uuid\":\"u\",\"timestamp\":\"\(iso(newer))\",\"message\":{\"role\":\"user\",\"content\":\"newer\"}}".utf8),
      to: projects.appendingPathComponent("newer.jsonl"))

    let summaries = ClaudeSessionLister.summaries(workspace: workspace,
                                                  claudeDirectory: claude,
                                                  fileSystem: fs)
    #expect(summaries.map(\.id) == ["newer", "older"])
  }

  @Test("summaries include resolved workspace transcript directory")
  func summariesIncludeResolvedWorkspaceDirectory() throws {
    let fs = InMemoryFileSystem()
    let workspace = URL(fileURLWithPath: "/var/codemixer-lister-test")
    let resolved = workspace.resolvingSymlinksInPath()
    let claude = URL(fileURLWithPath: "/tmp/claude")
    let projects = ClaudeProjectPaths.projectDirectory(for: resolved, claudeDirectory: claude)
    try fs.createDirectory(at: projects, withIntermediates: true)
    try fs.writeAtomically(
      Data("{\"type\":\"user\",\"uuid\":\"u\",\"timestamp\":\"\(iso(Date()))\",\"message\":{\"role\":\"user\",\"content\":\"resolved\"}}".utf8),
      to: projects.appendingPathComponent("resolved-session.jsonl"))

    let summaries = ClaudeSessionLister.summaries(workspace: workspace,
                                                  claudeDirectory: claude,
                                                  fileSystem: fs)
    #expect(summaries.map(\.id) == ["resolved-session"])
  }
}

private func iso(_ date: Date) -> String {
  ISO8601DateFormatter().string(from: date)
}
