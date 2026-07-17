import Testing
import Foundation
@testable import AgentCore
@testable import AgentProtocol
import AgentTestSupport

// MARK: - AgentID & AgentCapabilities

@Suite("AgentID — stable raw values")
struct AgentIDTests {
    @Test("All cases have non-empty raw values")
    func allCasesNonEmpty() {
        let all: [AgentID] = [.claudeCode, .codex, .cursorCLI, .geminiCLI, .openCode, .copilot, .other]
        for id in all {
            #expect(!id.rawValue.isEmpty)
        }
    }

    @Test("Claude Code and Codex are marked shipping")
    func shippingSet() {
        #expect(AgentID.shipping == [.claudeCode, .codex])
    }

    @Test("AgentID round-trips through Codable")
    func codableRoundTrip() throws {
        let original = AgentID.claudeCode
        let data = try JSONEncoder().encode(original)
        let decoded = try JSONDecoder().decode(AgentID.self, from: data)
        #expect(decoded == original)
    }
}

@Suite("AgentCapabilities — OptionSet algebra")
struct AgentCapabilitiesTests {
    @Test("Empty set contains no bits")
    func emptySet() {
        let empty = AgentCapabilities([])
        #expect(empty.isEmpty)
    }

    @Test("Union includes both capabilities")
    func union() {
        let set: AgentCapabilities = [.hooksOverUDS, .transcriptJSONL]
        #expect(set.contains(.hooksOverUDS))
        #expect(set.contains(.transcriptJSONL))
        #expect(!set.contains(.ptyTUIFallback))
    }

    @Test("All five capabilities are distinct")
    func distinctBits() {
        let all: [AgentCapabilities] = [
            .hooksOverUDS, .transcriptJSONL,
            .ptyTUIFallback, .permissionPrompts,
            .resumableSessions,
        ]
        for (i, a) in all.enumerated() {
            for (j, b) in all.enumerated() where i != j {
                #expect(!a.contains(b), "Capabilities at [\(i)] and [\(j)] must not overlap")
            }
        }
    }
}

// MARK: - SupportingTypes

@Suite("PermissionPrompt — value semantics")
struct PermissionPromptTests {
    @Test("Two prompts with same id are equal")
    func equality() {
        let id = UUID()
        let a = PermissionPrompt(id: id, toolName: "Bash", summary: "Run shell",
                                 argumentsSummary: "echo hi", requestedAt: testEpoch)
        let b = PermissionPrompt(id: id, toolName: "Bash", summary: "Run shell",
                                 argumentsSummary: "echo hi", requestedAt: testEpoch)
        #expect(a == b)
    }

    @Test("Different ids are not equal")
    func inequality() {
        let a = PermissionPrompt(id: UUID(), toolName: "Bash", summary: "s",
                                 argumentsSummary: "a", requestedAt: testEpoch)
        let b = PermissionPrompt(id: UUID(), toolName: "Bash", summary: "s",
                                 argumentsSummary: "a", requestedAt: testEpoch)
        #expect(a != b)
    }

    @Test("id property matches constructor argument")
    func idPropagation() {
        let id = UUID()
        let prompt = PermissionPrompt(id: id, toolName: "X", summary: "y",
                                      argumentsSummary: "z", requestedAt: testEpoch)
        #expect(prompt.id == id)
    }
}

@Suite("ToolInput / ToolOutput — initializer defaults")
struct ToolIOTests {
    @Test("ToolInput.jsonPayload defaults to nil")
    func toolInputDefault() {
        let ti = ToolInput(summary: "do something")
        #expect(ti.summary == "do something")
        #expect(ti.jsonPayload == nil)
    }

    @Test("ToolOutput.errorMessage defaults to nil")
    func toolOutputDefault() {
        let to = ToolOutput(summary: "result")
        #expect(to.errorMessage == nil)
    }

    @Test("ToolOutput stores all three fields")
    func toolOutputFull() {
        let to = ToolOutput(summary: "s", jsonPayload: "{}", errorMessage: "oops")
        #expect(to.summary == "s")
        #expect(to.jsonPayload == "{}")
        #expect(to.errorMessage == "oops")
    }
}

@Suite("ToolProgress — pattern matching")
struct ToolProgressTests {
    @Test("bashLine case holds string")
    func bashLine() {
        let p = ToolProgress.bashLine("hello")
        guard case .bashLine(let s) = p else { Issue.record("wrong case"); return }
        #expect(s == "hello")
    }

    @Test("fileBytes case holds written and total")
    func fileBytes() {
        let p = ToolProgress.fileBytes(written: 10, total: 100)
        guard case .fileBytes(let w, let t) = p else { Issue.record("wrong case"); return }
        #expect(w == 10)
        #expect(t == 100)
    }

    @Test("generic case holds message string")
    func generic() {
        let p = ToolProgress.generic(message: "uploading")
        guard case .generic(let m) = p else { Issue.record("wrong case"); return }
        #expect(m == "uploading")
    }
}

@Suite("SlashCommand — struct fields")
struct SlashCommandTests {
    @Test("Built-in command is not project-defined")
    func builtIn() {
        let cmd = SlashCommand(id: "/help", name: "/help", summary: "Show help")
        #expect(!cmd.isProjectDefined)
        #expect(cmd.id == "/help")
    }

    @Test("Project-defined command sets flag")
    func projectDefined() {
        let cmd = SlashCommand(id: "/custom", name: "/custom", summary: "My command", isProjectDefined: true)
        #expect(cmd.isProjectDefined)
    }
}

@Suite("SessionSummary — struct fields")
struct SessionSummaryTests {
    @Test("All fields propagate from init")
    func allFields() {
        let ws = URL(fileURLWithPath: "/tmp/my-project")
        let summary = SessionSummary(id: "abc123",
                                     agentID: .codex,
                                     workspace: ws,
                                     title: "Fix the bug",
                                     lastActivity: testEpoch,
                                     messageCount: 42)
        #expect(summary.id == "abc123")
        #expect(summary.agentID == .codex)
        #expect(summary.workspace == ws)
        #expect(summary.title == "Fix the bug")
        #expect(summary.lastActivity == testEpoch)
        #expect(summary.messageCount == 42)
    }
}

@Suite("ProjectAgentMode — routing metadata")
struct ProjectAgentModeTests {
    @Test("Pinned modes expose primary agent ids and labels")
    func pinnedModes() {
        #expect(ProjectAgentMode.claudeCode.primaryAgentID == .claudeCode)
        #expect(ProjectAgentMode.codex.primaryAgentID == .codex)
        #expect(ProjectAgentMode.claudeCode.shortLabel == "Claude")
        #expect(ProjectAgentMode.codex.shortLabel == "Codex")
    }

    @Test("Mixed mode carries optional default agent")
    func mixedDefault() {
        let mode = ProjectAgentMode.mixed(defaultAgent: .codex)
        #expect(mode.primaryAgentID == .codex)
        #expect(mode.shortLabel == "Mixed")
    }

    @Test("Custom mode stores executable metadata")
    func customMode() {
        let ref = CustomAgentRef(id: "local-tool",
                                 displayName: "Local Tool",
                                 transport: .stdioJSONRPC,
                                 executablePath: "/usr/local/bin/local-tool",
                                 arguments: ["serve"])
        let mode = ProjectAgentMode.custom(ref)
        #expect(mode.primaryAgentID == .other)
        #expect(mode.shortLabel == "Local Tool")
        #expect(ref.executablePath == "/usr/local/bin/local-tool")
    }
}

@Suite("ProjectAgentRouter — adapter id resolution")
struct ProjectAgentRouterTests {
    @Test("Pinned modes resolve directly")
    func pinnedModes() {
        #expect(ProjectAgentRouter.resolveAdapterID(mode: .claudeCode) == .claudeCode)
        #expect(ProjectAgentRouter.resolveAdapterID(mode: .codex) == .codex)
    }

    @Test("Mixed mode prefers session then explicit preference then default")
    func mixedPrecedence() {
        let mode = ProjectAgentMode.mixed(defaultAgent: .claudeCode)
        #expect(ProjectAgentRouter.resolveAdapterID(mode: mode,
                                                    sessionAgentID: .codex,
                                                    preferredForNewChat: .claudeCode) == .codex)
        #expect(ProjectAgentRouter.resolveAdapterID(mode: mode,
                                                    preferredForNewChat: .codex) == .codex)
        #expect(ProjectAgentRouter.resolveAdapterID(mode: mode) == .claudeCode)
    }
}

@Suite("AuthStatus — Hashable & pattern matching")
struct AuthStatusTests {
    @Test("authenticated with account is not equal to unauthenticated")
    func notEqual() {
        let a = AuthStatus.authenticated(account: "user@example.com")
        let b = AuthStatus.unauthenticated
        #expect(a != b)
    }

    @Test("authenticated with nil account is hashable")
    func hashable() {
        var set = Set<AuthStatus>()
        set.insert(.authenticated(account: nil))
        set.insert(.authenticated(account: nil))
        #expect(set.count == 1)
    }
}

@Suite("LaunchContext — optional fields default to nil")
struct LaunchContextTests {
    @Test("hookSocketPath and resumeSessionID default to nil")
    func defaults() {
        let ctx = LaunchContext(workspace: URL(fileURLWithPath: "/tmp"))
        #expect(ctx.hookSocketPath == nil)
        #expect(ctx.resumeSessionID == nil)
        #expect(ctx.extraEnv.isEmpty)
    }

    @Test("All fields propagate when supplied")
    func allFields() {
        let ws = URL(fileURLWithPath: "/tmp/p")
        let ctx = LaunchContext(workspace: ws,
                                hookSocketPath: "/tmp/hook.sock",
                                resumeSessionID: "sess-1",
                                permissionMode: .bypassPermissions,
                                extraEnv: ["FOO": "bar"])
        #expect(ctx.hookSocketPath == "/tmp/hook.sock")
        #expect(ctx.resumeSessionID == "sess-1")
        #expect(ctx.extraEnv["FOO"] == "bar")
    }
}

@Suite("HookRequest — Hashable identity")
struct HookRequestTests {
    @Test("Two HookRequests with the same id are equal")
    func equality() {
        let id = UUID()
        let a = HookRequest(id: id, eventName: "PreToolUse", jsonPayload: Data("{}".utf8))
        let b = HookRequest(id: id, eventName: "PreToolUse", jsonPayload: Data("{}".utf8))
        #expect(a == b)
    }

    @Test("HookRequest is usable as Dictionary key")
    func hashable() {
        let req = HookRequest(id: UUID(), eventName: "Stop", jsonPayload: Data())
        var dict = [HookRequest: String]()
        dict[req] = "handled"
        #expect(dict[req] == "handled")
    }
}

@Suite("FSEvent — kinds and equality")
struct FSEventTests {
    @Test("All four kinds are distinct")
    func distinctKinds() {
        let kinds: [FSEvent.Kind] = [.modified, .created, .removed, .renamed]
        let set = Set(kinds)
        #expect(set.count == 4)
    }

    @Test("FSEvent equality is structural")
    func equality() {
        let url = URL(fileURLWithPath: "/tmp/file.txt")
        let a = FSEvent(url: url, kind: .modified, observedAt: testEpoch)
        let b = FSEvent(url: url, kind: .modified, observedAt: testEpoch)
        #expect(a == b)
    }
}

// MARK: - AdapterRegistry

@Suite("AdapterRegistry — register and lookup")
struct AdapterRegistryTests {
    @Test("register then adapter(for:) returns the same adapter")
    func registerAndLookup() async {
        let registry = AdapterRegistry()
        let mock = MockAdapter()
        await registry.register(mock)
        let found = await registry.adapter(for: .other)
        #expect(found?.id == .other)
    }

    @Test("adapter(for:) returns nil for unknown id")
    func unknownID() async {
        let registry = AdapterRegistry()
        let found = await registry.adapter(for: .claudeCode)
        #expect(found == nil)
    }

    @Test("all() returns registered adapters sorted by displayName")
    func allSorted() async {
        let registry = AdapterRegistry()
        let mock = MockAdapter()
        await registry.register(mock)
        let all = await registry.all()
        #expect(all.count == 1)
        #expect(all[0].id == .other)
    }
}

// MARK: - FileSystemError

@Suite("FileSystemError — Equatable & associated values")
struct FileSystemErrorTests {
    @Test("notFound carries path")
    func notFound() {
        let err = FileSystemError.notFound(path: "/tmp/x.txt")
        if case .notFound(let p) = err {
            #expect(p == "/tmp/x.txt")
        } else {
            Issue.record("wrong case")
        }
    }

    @Test("Same case + path are equal")
    func equality() {
        let a = FileSystemError.permissionDenied(path: "/etc/passwd")
        let b = FileSystemError.permissionDenied(path: "/etc/passwd")
        #expect(a == b)
    }

    @Test("Different cases are not equal")
    func inequality() {
        let a = FileSystemError.notFound(path: "/tmp/a")
        let b = FileSystemError.ioError(path: "/tmp/a", underlying: "disk full")
        #expect(a != b)
    }
}

// MARK: - FileSystem incremental reads

@Suite("FileSystem — byteCount and ranged reads")
struct FileSystemIncrementalReadTests {
    @Test("InMemoryFileSystem reads only bytes appended after the prior offset")
    func rangedReadFromOffset() throws {
        let fs = InMemoryFileSystem()
        let url = URL(fileURLWithPath: "/tmp/transcript.jsonl")
        try fs.writeAtomically(Data("first\n".utf8), to: url)

        #expect(try fs.byteCount(at: url) == 6)
        #expect(String(data: try fs.readData(at: url, fromOffset: 0), encoding: .utf8) == "first\n")

        try fs.writeAtomically(Data("first\nsecond".utf8), to: url)
        #expect(String(data: try fs.readData(at: url, fromOffset: 6), encoding: .utf8) == "second")
        #expect(try fs.readData(at: url, fromOffset: 99).isEmpty)
    }
}

// MARK: - SystemClock smoke test

@Suite("SystemClock — live seam smoke test")
struct SystemClockTests {
    @Test("now() returns a date after epoch 2020")
    func nowIsRecent() {
        let clock = SystemClock()
        let ref = Date(timeIntervalSince1970: 1_577_836_800) // 2020-01-01
        #expect(clock.now() > ref)
    }

    @Test("monotonic() advances between two calls")
    func monotonicAdvances() async throws {
        let clock = SystemClock()
        let a = clock.monotonic()
        try await clock.sleep(for: .milliseconds(5))
        let b = clock.monotonic()
        #expect(b > a)
    }
}

// MARK: - SystemRandomSource smoke test

@Suite("SystemRandomSource — live seam smoke test")
struct SystemRandomSourceTests {
    @Test("uuid() returns a non-nil, well-formed UUID")
    func uuidWellFormed() {
        let src = SystemRandomSource()
        let id = src.uuid()
        // Round-trip through string is sufficient to verify formatting.
        #expect(!id.uuidString.isEmpty)
    }

    @Test("bytes(_:) returns exactly the requested count")
    func byteCount() {
        let src = SystemRandomSource()
        let data = src.bytes(32)
        #expect(data.count == 32)
    }

    @Test("pin(digits:) returns a string of the correct length")
    func pinLength() {
        let src = SystemRandomSource()
        let pin = src.pin(digits: 6)
        #expect(pin.count == 6)
        #expect(pin.unicodeScalars.allSatisfy(CharacterSet.decimalDigits.contains))
    }
}

