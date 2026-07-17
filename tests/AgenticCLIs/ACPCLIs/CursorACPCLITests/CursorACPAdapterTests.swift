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

    @Test("session modes expose agent plan ask for composer")
    func sessionModes() {
        let modes = CursorACPAdapter().availableSessionModes()
        #expect(modes.map(\.id) == ["agent", "plan", "ask"])
        #expect(modes.map(\.label) == ["Agent", "Plan", "Ask"])
        #expect(modes.allSatisfy { option in
            option.selectCommands == [.runSlashCommand(name: "/\(option.id)", args: [])]
        })
    }

    @Test("AgentID.shipping includes cursorCLI")
    func shipping() {
        #expect(AgentID.shipping.contains(.cursorCLI))
        #expect(SupportedBuiltInAgent.shipping.contains { $0.id == .cursorCLI })
        #expect(SupportedBuiltInAgent.entry(for: .cursorCLI)?.projectMode == .cursorCLI)
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
