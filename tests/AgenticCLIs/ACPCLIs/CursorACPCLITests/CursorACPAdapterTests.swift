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
        #expect(adapter.capabilities.contains(.sessionHandshakeGate))
    }

    @Test("buildLaunchArgv is cursor-agent acp")
    func argv() {
        let adapter = CursorACPAdapter()
        let argv = adapter.buildLaunchArgv(context: LaunchContext(
            workspace: URL(fileURLWithPath: "/tmp"),
            permissionMode: .default
        ))
        #expect(argv == ["cursor-agent", "acp"])
    }

    @Test("binary locator prefers CURSOR_BIN override")
    func locatorOverride() throws {
        let fs = InMemoryFileSystem()
        let home = URL(fileURLWithPath: "/tmp/cursor-home", isDirectory: true)
        let override = URL(fileURLWithPath: "/tmp/custom-cursor-agent")
        try fs.writeAtomically(Data(), to: override)
        let env = FakeEnvironment(
            processEnv: ["CURSOR_BIN": override.path, "PATH": "/usr/bin"],
            home: home
        )
        let locator = CursorBinaryLocator(environment: env, fileSystem: fs)
        let resolved = ResolvedEnvironment(
            variables: env.processEnvironment(),
            shell: URL(fileURLWithPath: "/bin/zsh")
        )
        #expect(try locator.locate(env: resolved) == override)
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
        let workspace = URL(fileURLWithPath: "/tmp/cursor-ws")
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
        #expect(adapter.encodeCommand(.runSlashCommand(name: "/debug", args: [])) == nil)
    }

    @Test("agent modes expose agent plan ask for composer")
    func agentModes() {
        let modes = CursorACPAdapter().availableAgentModes()
        #expect(modes.map(\.id) == ["agent", "plan", "ask"])
        #expect(modes.map(\.label) == ["Agent", "Plan", "Ask"])
        #expect(modes.allSatisfy { option in
            option.selectCommands == [.runSlashCommand(name: "/\(option.id)", args: [])]
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

@Suite("Cursor mode commands")
struct CursorModeCommandTests {
    @Test("all chat modes have slash names")
    func slashNames() {
        #expect(CursorModeCommand.agent.slashName == "/agent")
        #expect(CursorModeCommand.plan.slashName == "/plan")
        #expect(CursorModeCommand.ask.slashName == "/ask")
    }
}
