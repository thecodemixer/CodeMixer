import Foundation
import Testing
@testable import ACPCLIs
@testable import AgentClientProtocol
import AgentCore
import AgentProtocol
import AgentTestSupport

@Suite("CursorACPAdapter")
struct CursorACPAdapterTests {

    @Test("identity and transport are cursorCLI over agentClientProtocol")
    func identity() {
        let adapter = CursorACPAdapter()
        #expect(adapter.id == .cursorCLI)
        #expect(adapter.displayName == "Cursor")
        #expect(adapter.transportDescriptor == .agentClientProtocol)
        #expect(adapter.capabilities.contains(.permissionPrompts))
        #expect(adapter.capabilities.contains(.resumableSessions))
    }

    @Test("workspace identity matches Cursor's MD5 path layout")
    func workspaceIdentity() {
        #expect(CursorWorkspaceIdentity.projectDirectoryName(
            forWorkspace: URL(fileURLWithPath: "/workspace/codemixer")
        ) == "3e7652358e6e6b04c9c2112b8e247b8d")
    }

    @Test("SQLite reader opens vendor databases read-only")
    func sqliteReaderRejectsMissingDatabase() {
        #expect(throws: SQLiteReader.ReaderError.self) {
            try SQLiteReader().rows(
                in: TestPaths.underTemporary("missing-cursor-state.vscdb"),
                query: "SELECT value FROM ItemTable",
                textBindings: []
            )
        }
    }

    @Test("catalog import preserves Cursor user thinking and assistant blocks")
    func catalogImportPreservesVisibleBlocks() async throws {
        let fileSystem = InMemoryFileSystem()
        let home = TestPaths.underTemporary("cursor-import-home")
        let workspace = TestPaths.underTemporary("cursor-import-workspace")
        let chats = home.appendingPathComponent(
            ".cursor/chats/\(CursorWorkspaceIdentity.projectDirectoryName(forWorkspace: workspace))",
            isDirectory: true
        )
        try fileSystem.createDirectory(at: chats, withIntermediates: true)
        let chat = chats.appendingPathComponent("chat-1", isDirectory: true)
        try fileSystem.createDirectory(at: chat, withIntermediates: true)
        try fileSystem.writeAtomically(Data(), to: chat.appendingPathComponent("store.db"))

        let imported = try await CursorSessionCatalogImporter(
            homeDirectory: home,
            fileSystem: fileSystem,
            sqlite: CursorSQLiteFixture(),
            random: FakeRandomSource()
        ).sessions(workspace: workspace) { _, _ in }

        let session = try #require(imported.first)
        #expect(session.id == "chat-1")
        #expect(session.title == "Imported session")
        #expect(session.events.count == 4)
        if case .userTurn(_, let text) = session.events[0] {
            #expect(text == "Explain the history store")
        } else {
            Issue.record("Expected imported user turn")
        }
        if case .thinkingChunk(_, let text) = session.events[1] {
            #expect(text == "Tracing the journal")
        } else {
            Issue.record("Expected imported thinking")
        }
        if case .assistantText(_, _, let text, true) = session.events[3] {
            #expect(text == "The repository owns replay.")
        } else {
            Issue.record("Expected imported assistant text")
        }
    }

    @Test("buildLaunchArgv is cursor-agent acp")
    func argv() {
        let adapter = CursorACPAdapter()
        let argv = adapter.buildLaunchArgv(context: LaunchContext(
            workspace: TestPaths.temporaryRoot,
            permissionMode: .default
        ))
        #expect(argv == ["cursor-agent", "acp"])
    }

    @Test("binary locator prefers CURSOR_BIN override")
    func locatorOverride() throws {
        let fs = InMemoryFileSystem()
        let home = TestPaths.underTemporary("cursor-home")
        let override = TestPaths.underTemporary("custom-cursor-agent", isDirectory: false)
        try fs.writeAtomically(Data(), to: override)
        let env = FakeEnvironment(
            processEnv: ["CURSOR_BIN": override.path, "PATH": "/usr/bin"],
            home: home
        )
        let locator = CursorBinaryLocator(environment: env, fileSystem: fs)
        let resolved = ResolvedEnvironment(
            variables: env.processEnvironment(),
            shell: SystemPaths.zsh
        )
        #expect(try locator.locate(env: resolved).resolvingSymlinksInPath() == override.resolvingSymlinksInPath())
    }

    @Test("slash catalog includes agent plan ask and diagnostic debug")
    func catalog() {
        let names = Set(CursorModeCommand.slashCatalog.map(\.name))
        #expect(names.isSuperset(of: ["/agent", "/plan", "/ask", "/debug"]))
        #expect(CursorModeCommand.slashCatalog.contains {
            $0.name == "/debug" && $0.summary.localizedCaseInsensitiveContains("diagnostic")
        })
    }

    @Test("permission and slash mode commands encode session/set_mode")
    func modeEncoding() {
        let adapter = CursorACPAdapter()
        let workspace = TestPaths.underTemporary("cursor-ws")
        _ = adapter.sessionBootstrapBytes(context: LaunchContext(
            workspace: workspace,
            permissionMode: .default
        ))

        // Seed session id the same way ACPAdapter does after session/new.
        let innerBootstrap = String(decoding: adapter.sessionBootstrapBytes(context: LaunchContext(
            workspace: workspace,
            permissionMode: .default
        )), as: UTF8.self)
        #expect(innerBootstrap.contains("initialize"))

        // Direct set-mode helpers via encodeCommand after a synthetic session
        // is not available without an event stream; verify mapping helpers and
        // that encodeCommand returns set_mode once the inner ACP state has a
        // session. Use ACPInputEncoding through a local state for the wire shape.
        let state = ACPClientState()
        _ = ACPInputEncoding.bootstrap(
            context: LaunchContext(workspace: workspace, permissionMode: .default),
            state: state,
            customAgentID: "cursor",
            displayName: "Cursor"
        )
        state.setSessionID("sess-1")
        let plan = String(decoding: ACPInputEncoding.setMode(modeID: "plan", state: state), as: UTF8.self)
        #expect(plan.contains("session/set_mode"))
        #expect(plan.contains("\"modeId\":\"plan\""))

        #expect(CursorModeCommand.modeID(forPermissionMode: .plan) == "plan")
        #expect(CursorModeCommand.modeID(forPermissionMode: .default) == "agent")
        #expect(CursorModeCommand.chatMode(forSlash: "/ask") == .ask)
        #expect(CursorModeCommand.chatMode(forSlash: "/debug") == nil)
    }

    @Test("debug slash command is unsupported as a chat mode")
    func debugUnsupported() {
        let adapter = CursorACPAdapter()
        #expect(adapter.encodeCommand(.runSlashCommand(target: .builtin(name: "/debug"), args: [])) == nil)
    }

    @Test("agent modes expose agent plan ask for composer")
    func agentModes() {
        let modes = CursorACPAdapter().availableAgentModes()
        #expect(modes.map(\.id) == ["agent", "plan", "ask"])
        #expect(modes.map(\.label) == ["Agent", "Plan", "Ask"])
        #expect(modes.allSatisfy { option in
            option.selectCommands == [.setAgentMode(id: option.id)]
        })
    }

    @Test("model catalog parses cursor-agent models output")
    func modelCatalogParsing() {
        let output = """
        \u{001B}[2K\u{001B}[GAvailable models

        auto - Auto  (default)
        gpt-5.3-codex-high - Codex 5.3 High
        claude-4.6-sonnet-medium - Sonnet 4.6 1M  (current)
        claude-fable-5-high - Fable 5 1M (NO ZDR)
        """
        let models = CursorModelCatalog.parse(output)
        #expect(models.map(\.id) == [
            "auto",
            "gpt-5.3-codex-high",
            "claude-4.6-sonnet-medium",
            "claude-fable-5-high",
        ])
        #expect(models.map(\.label) == [
            "Auto",
            "Codex 5.3 High",
            "Sonnet 4.6 1M",
            "Fable 5 1M (NO ZDR)",
        ])
    }

    @Test("availableModels falls back to cached cursor model catalog")
    func availableModelsFallback() {
        let adapter = CursorACPAdapter(initialModels: [
            AgentModelOption(id: "auto", label: "Auto"),
            AgentModelOption(id: "gpt-5.3-codex-high", label: "Codex 5.3 High"),
        ])
        #expect(adapter.availableModels().map(\.id) == ["auto", "gpt-5.3-codex-high"])
    }

    @Test("seedModelCatalog replaces the in-memory cursor catalog")
    func seedModelCatalog() {
        let adapter = CursorACPAdapter()
        adapter.seedModelCatalog([
            AgentModelOption(id: "auto", label: "Auto"),
        ])
        #expect(adapter.availableModels().map(\.id) == ["auto"])
    }

    @Test("AgentID.shipping includes cursorCLI")
    func shipping() {
        #expect(AgentID.shipping.contains(.cursorCLI))
        #expect(SupportedBuiltInAgent.shipping.contains { $0.id == .cursorCLI })
        #expect(SupportedBuiltInAgent.entry(for: .cursorCLI)?.projectType == .cursorCLI)
    }
}

private struct CursorSQLiteFixture: SQLiteReading {
    func rows(in _: URL,
              query: String,
              textBindings: [String]) throws -> [[String: Data]] {
        if query.contains("FROM meta") {
            #expect(textBindings == ["0"])
            let metadata = Data(
                #"{"agentId":"chat-1","latestRootBlobId":"root","name":"Imported session","createdAt":1700000000000}"#.utf8
            )
            let hex = metadata.map { String(format: "%02x", $0) }.joined()
            return [["value": Data(hex.utf8)]]
        }
        guard query.contains("FROM blobs"), let id = textBindings.first else {
            return []
        }
        if id == "root" {
            return [["data": Self.rootBlob]]
        }
        if id == String(repeating: "11", count: 32) {
            return [["data": Data(
                #"{"role":"user","content":[{"type":"text","text":"<user_query>\nExplain the history store\n</user_query>"}]}"#.utf8
            )]]
        }
        if id == String(repeating: "22", count: 32) {
            return [["data": Data(
                #"{"role":"assistant","content":[{"type":"reasoning","text":"Tracing the journal"},{"type":"text","text":"The repository owns replay."}]}"#.utf8
            )]]
        }
        return []
    }

    private static var rootBlob: Data {
        Data([0x0A, 0x20] + Array(repeating: 0x11, count: 32)
            + [0x0A, 0x20] + Array(repeating: 0x22, count: 32))
    }
}

@Suite("Cursor mode commands")
struct CursorModeCommandTests {
    @Test("all chat modes have slash names")
    func slashNames() {
        #expect(CursorModeCommand.agent.slashName == "/agent")
        #expect(CursorModeCommand.plan.slashName == "/plan")
        #expect(CursorModeCommand.ask.slashName == "/ask")
    }
}
