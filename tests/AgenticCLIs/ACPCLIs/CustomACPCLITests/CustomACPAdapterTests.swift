import Foundation
import Testing
@testable import ACPCLIs
@testable import AgentClientProtocol
import AgentCore
import AgentProtocol
import AgentTestSupport

@Suite("CustomACPAdapter")
struct CustomACPAdapterTests {

    private func sampleRef(id: String = "migration-assistant",
                           path: String = SystemPaths.binary(in: SystemPaths.usrLocalBin, named: "migration-acp").path) -> CustomAgentRef {
        CustomAgentRef(
            id: id,
            displayName: "Migration Assistant",
            transport: .agentClientProtocol,
            executablePath: path,
            arguments: ["acp"]
        )
    }

    @Test("identity comes from CustomAgentRef")
    func identity() {
        let adapter = CustomACPAdapter(ref: sampleRef())
        #expect(adapter.id == .other)
        #expect(adapter.displayName == "Migration Assistant")
        #expect(adapter.transportDescriptor == .agentClientProtocol)
        #expect(adapter.capabilities.contains(.resumableSessions))
        #expect(adapter.capabilities.contains(.sessionHandshakeGate))
    }

    @Test("buildLaunchArgv uses exe basename plus ref arguments")
    func argv() {
        let adapter = CustomACPAdapter(ref: sampleRef(path: "/opt/tools/migration-acp"))
        let argv = adapter.buildLaunchArgv(context: LaunchContext(
            workspace: TestPaths.temporaryRoot,
            permissionMode: .default
        ))
        #expect(argv == ["migration-acp", "acp"])
    }

    @Test("binary locator prefers CODEMIXER_CUSTOM_ACP_BIN")
    func locatorOverride() throws {
        let fs = InMemoryFileSystem()
        let override = TestPaths.underTemporary("custom-acp-bin", isDirectory: false)
        try fs.writeAtomically(Data(), to: override)
        let env = FakeEnvironment(
            processEnv: [
                "CODEMIXER_CUSTOM_ACP_BIN": override.path,
                "PATH": "/usr/bin",
            ],
            home: TestPaths.underTemporary("home")
        )
        let locator = CustomACPBinaryLocator(
            executablePath: "/missing/migration-acp",
            displayName: "Migration",
            environment: env,
            fileSystem: fs
        )
        let resolved = ResolvedEnvironment(
            variables: env.processEnvironment(),
            shell: SystemPaths.zsh
        )
        #expect(try locator.locate(env: resolved).resolvingSymlinksInPath() == override.resolvingSymlinksInPath())
    }

    @Test("binary locator finds basename on PATH when absolute path is missing")
    func locatorPathBasename() throws {
        let fs = InMemoryFileSystem()
        let onPath = URL(fileURLWithPath: "/opt/bin/migration-acp")
        try fs.writeAtomically(Data(), to: onPath)
        let env = FakeEnvironment(
            processEnv: ["PATH": "/opt/bin:/usr/bin"],
            home: TestPaths.underTemporary("home")
        )
        let locator = CustomACPBinaryLocator(
            executablePath: "migration-acp",
            displayName: "Migration",
            environment: env,
            fileSystem: fs
        )
        let resolved = ResolvedEnvironment(
            variables: env.processEnvironment(),
            shell: SystemPaths.zsh
        )
        #expect(try locator.locate(env: resolved) == onPath)
    }

    @Test("mode mapping orders current mode first and remaps slash/permission")
    func modeMapping() {
        let modes = [
            ACPSessionMode(id: "agent", name: "Agent", description: "Full"),
            ACPSessionMode(id: "plan", name: "Plan", description: "Read-only"),
            ACPSessionMode(id: "ask", name: "Ask", description: "Q&A"),
        ]
        let ordered = CustomACPModeMapping.agentModes(from: modes, currentModeID: "plan")
        #expect(ordered.map(\.id) == ["plan", "agent", "ask"])
        #expect(CustomACPModeMapping.modeID(forSlash: "/ask", available: modes) == "ask")
        #expect(CustomACPModeMapping.modeID(forPermissionMode: .plan, available: modes) == "plan")
        #expect(CustomACPModeMapping.modeID(forPermissionMode: .default, available: modes) == "agent")
        let catalog = CustomACPModeMapping.slashCatalog(from: modes)
        #expect(catalog.contains { $0.name == "/plan" && $0.summary == "Read-only" })
    }

    @Test("factory caches equal refs and rebuilds when ref fields change")
    func factoryCache() {
        let factory = CustomACPAdapterFactory()
        let ref = sampleRef()
        let first = factory.makeAdapter(for: ref) as? CustomACPAdapter
        let second = factory.makeAdapter(for: ref) as? CustomACPAdapter
        #expect(first != nil)
        #expect(second != nil)
        #expect(ObjectIdentifier(first!) == ObjectIdentifier(second!))

        let renamed = CustomAgentRef(
            id: ref.id,
            displayName: "Renamed",
            transport: .agentClientProtocol,
            executablePath: ref.executablePath,
            arguments: ref.arguments
        )
        let third = factory.makeAdapter(for: renamed) as? CustomACPAdapter
        #expect(third != nil)
        #expect(ObjectIdentifier(first!) != ObjectIdentifier(third!))
        #expect(third?.displayName == "Renamed")

        #expect(factory.makeAdapter(for: CustomAgentRef(
            id: "x",
            displayName: "Stdio",
            transport: .stdioJSONRPC,
            executablePath: "/bin/x",
            arguments: []
        )) == nil)
    }

    @Test("cached factory adapter surfaces modes after session/new (composer refresh)")
    func factoryModesVisibleAfterSessionNew() async throws {
        let factory = CustomACPAdapterFactory()
        let ref = sampleRef(id: "composer-refresh", path: SystemPaths.trueBinary.path)
        guard let adapter = factory.makeAdapter(for: ref) as? CustomACPAdapter else {
            Issue.record("expected CustomACPAdapter")
            return
        }
        #expect(adapter.availableAgentModes().isEmpty)

        let workspace = TestPaths.underTemporary("custom-composer-ws")
        let (outputBytes, outputContinuation) = AsyncStream<Data>.makeStream()
        let inputs = AgentInputs(
            outputBytes: outputBytes,
            writeBytes: { _ in },
            terminal: nil,
            hookSocket: nil,
            workspace: workspace,
            sessionID: AsyncStream { $0.finish() }
        )
        _ = adapter.sessionBootstrapBytes(context: LaunchContext(
            workspace: workspace,
            permissionMode: .default
        ))
        let stream = adapter.makeEventStream(inputs: inputs)
        let consumer = Task {
            for await _ in stream {}
        }
        defer {
            outputContinuation.finish()
            consumer.cancel()
        }

        yieldInitializeAndSessionNew(
            continuation: outputContinuation,
            sessionID: "composer-sess",
            modes: [
                ["id": "migrate", "name": "Migrate", "description": "Migrations"],
                ["id": "document", "name": "Document", "description": "Docs"],
                ["id": "agent", "name": "Agent"],
            ],
            currentModeID: "migrate"
        )

        let sawModes = await pollUntil(timeout: .seconds(2)) {
            Set(adapter.availableAgentModes().map(\.id)) == Set(["migrate", "document", "agent"])
        }
        #expect(sawModes)

        // Composer reads modes from the same factory-cached instance.
        let cached = factory.makeAdapter(for: ref) as? CustomACPAdapter
        #expect(cached != nil)
        #expect(ObjectIdentifier(adapter) == ObjectIdentifier(cached!))
        #expect(Set(cached!.availableAgentModes().map(\.id)) == Set(["migrate", "document", "agent"]))
        #expect(cached!.availableAgentModes().first?.id == "migrate")
    }

    @Test("encodeCommand remaps /document slash to session/set_mode after session modes load")
    func encodeDocumentModeWire() async throws {
        let ref = sampleRef(id: "wire-test", path: SystemPaths.trueBinary.path)
        let adapter = CustomACPAdapter(
            ref: ref,
            environment: FakeEnvironment(),
            fileSystem: InMemoryFileSystem(),
            clock: FakeClock(),
            random: FakeRandomSource()
        )
        let workspace = TestPaths.underTemporary("custom-wire-ws")
        let (outputBytes, outputContinuation) = AsyncStream<Data>.makeStream()
        let inputs = AgentInputs(
            outputBytes: outputBytes,
            writeBytes: { _ in },
            terminal: nil,
            hookSocket: nil,
            workspace: workspace,
            sessionID: AsyncStream { $0.finish() }
        )
        _ = adapter.sessionBootstrapBytes(context: LaunchContext(
            workspace: workspace,
            permissionMode: .default
        ))
        let stream = adapter.makeEventStream(inputs: inputs)
        let consumer = Task {
            for await _ in stream {}
        }
        defer {
            outputContinuation.finish()
            consumer.cancel()
        }

        yieldInitializeAndSessionNew(
            continuation: outputContinuation,
            sessionID: "wire-sess",
            modes: [
                ["id": "migrate", "name": "Migrate", "description": "Migrations"],
                ["id": "document", "name": "Document", "description": "Docs"],
                ["id": "agent", "name": "Agent"],
            ],
            currentModeID: "migrate"
        )

        let sawModes = await pollUntil(timeout: .seconds(2)) {
            Set(adapter.availableAgentModes().map(\.id)) == Set(["migrate", "document", "agent"])
        }
        #expect(sawModes)
        #expect(adapter.availableAgentModes().first?.id == "migrate")
        #expect(adapter.slashCommandCatalog.contains {
            $0.name == "/document" && $0.summary == "Docs"
        })

        let encoded = adapter.encodeCommand(.runSlashCommand(target: .builtin(name: "/document"), args: []))
        #expect(encoded != nil)
        let text = String(decoding: encoded!, as: UTF8.self)
        #expect(text.contains("\"method\":\"session/set_mode\""))
        #expect(text.contains("\"modeId\":\"document\""))

        let planEncoded = adapter.encodeCommand(.setPermissionMode(.plan))
        #expect(planEncoded == nil)
    }
}

private func yieldInitializeAndSessionNew(
    continuation: AsyncStream<Data>.Continuation,
    sessionID: String,
    modes: [[String: Any]],
    currentModeID: String
) {
    continuation.yield(encodeJSONRPC([
        "jsonrpc": "2.0",
        "id": 1,
        "result": [
            "protocolVersion": 1,
            "agentCapabilities": [:] as [String: Any],
            "authMethods": [] as [Any],
        ],
    ]))
    continuation.yield(encodeJSONRPC([
        "jsonrpc": "2.0",
        "id": 2,
        "result": [
            "sessionId": sessionID,
            "modes": [
                "currentModeId": currentModeID,
                "availableModes": modes,
            ],
        ],
    ]))
}

private func encodeJSONRPC(_ object: [String: Any]) -> Data {
    ACPFraming.frame(try! JSONSerialization.data(withJSONObject: object))
}

private func pollUntil(timeout: Duration, _ condition: @escaping @Sendable () async -> Bool) async -> Bool {
    let deadline = ContinuousClock.now + timeout
    while ContinuousClock.now < deadline {
        if await condition() { return true }
        try? await Task.sleep(for: .milliseconds(20))
    }
    return await condition()
}
