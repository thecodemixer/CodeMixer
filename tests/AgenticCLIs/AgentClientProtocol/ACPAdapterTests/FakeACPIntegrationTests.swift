import Foundation
import Testing
@testable import AgentClientProtocol
@testable import AgentCore
import AgentProtocol
import AgentTestSupport

/// Production-path coverage for `ACPAdapter` and the `fake-acp` stdio server.
@Suite("AgentEngine + ACPAdapter + fake-acp", .serialized)
struct FakeACPIntegrationTests {

    @Test("spawned fake-acp text turn emits assistantText through production adapter path")
    func spawnedTextTurn() async throws {
        try await runScenario(
            scenario: "text",
            prompt: "hello twin",
            until: { $0.containsFinalAssistantText(containing: "Hello from fake-acp.") },
            assert: { events in
                #expect(events.contains {
                    if case .sessionStarted(let id, _, _) = $0 { return !id.isEmpty }
                    return false
                })
                #expect(events.contains {
                    if case .userTurn(_, let text) = $0 { return text == "hello twin" }
                    return false
                })
                #expect(events.contains {
                    if case .assistantText(_, _, let text, let isFinal) = $0 {
                        return isFinal && text.contains("Hello from fake-acp.")
                    }
                    return false
                })
            }
        )
    }

    @Test("spawned fake-acp permission turn surfaces permissionRequest and completes after allow")
    func spawnedPermissionTurn() async throws {
        try await runScenario(
            scenario: "permission",
            prompt: "run tool",
            until: { events in
                events.containsPermissionRequest() && events.containsFinalAssistantText(containing: "Hello from fake-acp.")
            },
            autoApprovePermissions: true,
            assert: { events in
                #expect(events.containsPermissionRequest())
                #expect(events.containsFinalAssistantText(containing: "Hello from fake-acp."))
            }
        )
    }

    @Test("spawned fake-acp fs-read reverse RPC returns workspace file content in reply")
    func spawnedFSReadTurn() async throws {
        let workspace = try makeWorkspace()
        let probe = workspace.appendingPathComponent("probe.txt")
        try Data("acp-probe".utf8).write(to: probe)

        try await runScenario(
            scenario: "fsRead",
            workspace: workspace,
            prompt: "read file",
            until: { $0.containsFinalAssistantText(containing: "fs:acp-probe") },
            assert: { events in
                #expect(events.containsFinalAssistantText(containing: "fs:acp-probe"))
            }
        )
    }

    @Test("spawned fake-acp auth-fail scenario emits authenticationRequired")
    func spawnedAuthRequired() async throws {
        try await runScenario(
            scenario: "authFail",
            prompt: "hello",
            until: { $0.containsAuthenticationRequired() },
            assert: { events in
                #expect(events.containsAuthenticationRequired())
            },
            sendPrompt: false
        )
    }

    @Test("spawned fake-acp auth scenario authenticates and completes turn")
    func spawnedAuthSuccess() async throws {
        try await runScenario(
            scenario: "auth",
            prompt: "hello",
            until: { $0.containsFinalAssistantText(containing: "authenticated fake-acp") },
            assert: { events in
                #expect(events.containsFinalAssistantText(containing: "authenticated fake-acp"))
            }
        )
    }

    @Test("spawned fake-acp resume uses session/load and preserves resume id")
    func spawnedResumeTurn() async throws {
        let resumeID = "resume-\(UUID().uuidString)"
        try await runScenario(
            scenario: "resume",
            resumeSessionID: resumeID,
            prompt: "continue",
            until: { $0.containsFinalAssistantText(containing: "Hello from fake-acp.") },
            assert: { events in
                #expect(events.contains {
                    if case .sessionStarted(let id, _, _) = $0 { return id == resumeID }
                    return false
                })
                #expect(events.contains {
                    if case .userTurn(_, let text) = $0 { return text.contains("prior user") }
                    return false
                })
                #expect(events.contains {
                    if case .assistantText(_, _, let text, true) = $0 {
                        return text.contains("prior assistant")
                    }
                    return false
                })
            }
        )
    }

    @Test("adapter permission response writes ACP selected outcome bytes")
    func adapterPermissionRoundTrip() async throws {
        let adapter = acpAdapter()
        let workspace = URL(fileURLWithPath: "/tmp/acp-perm")
        let (outputBytes, outputContinuation) = AsyncStream<Data>.makeStream()
        let inputs = AgentInputs(
            outputBytes: outputBytes,
            terminal: nil,
            hookSocket: nil,
            workspace: workspace,
            sessionID: AsyncStream { $0.finish() }
        )
        _ = adapter.sessionBootstrapBytes(context: LaunchContext(workspace: workspace, permissionMode: .default))

        let stream = adapter.makeEventStream(inputs: inputs)
        let consumer = Task {
            var events: [AgentEvent] = []
            for await event in stream {
                events.append(event)
            }
            return events
        }

        outputContinuation.yield(Data("""
        {"jsonrpc":"2.0","id":50,"method":"session/request_permission","params":{"options":[{"kind":"allow_once","optionId":"allow-once"}],"toolCall":{"title":"Shell"}}}
        """.utf8 + [0x0A]))
        outputContinuation.finish()

        let events = await consumer.value
        guard let prompt = events.compactMap({
            if case .permissionRequest(let prompt) = $0 { return prompt }
            return nil
        }).first else {
            Issue.record("missing permission prompt")
            return
        }

        guard case .writePTY(let data) = adapter.encodePermissionResponse(.allow, for: prompt) else {
            Issue.record("expected writePTY")
            return
        }
        let text = String(decoding: data, as: UTF8.self)
        #expect(text.contains("\"optionId\":\"allow-once\""))
        #expect(text.contains("\"outcome\":\"selected\""))
    }

    // MARK: - Driver

    private func runScenario(scenario: String,
                             workspace: URL? = nil,
                             resumeSessionID: String? = nil,
                             prompt: String,
                             until: @escaping @Sendable ([AgentEvent]) -> Bool,
                             autoApprovePermissions: Bool = false,
                             assert: @escaping ([AgentEvent]) -> Void,
                             sendPrompt: Bool = true) async throws {
        guard let fakeBin = Self.locateFakeACP() else {
            Issue.record("fake-acp not built — run swift build --product fake-acp")
            return
        }

        let ws = try workspace ?? makeWorkspace()
        defer { if workspace == nil { try? FileManager.default.removeItem(at: ws) } }

        let env = FakeEnvironment(processEnv: [
            "CODEMIXER_TWIN_SCENARIO": scenario,
            "PATH": "/usr/bin:/bin:/usr/sbin:/sbin",
            "SHELL": "/codemixer-test/missing-shell",
        ])
        let fs = SystemFileSystem()
        let engine = AgentEngine(seams: Seams(
            clock: SystemClock(),
            random: SystemRandomSource(),
            environment: env,
            fileSystem: fs
        ))
        await engine.bootstrap()

        let adapter = ACPAdapter(
            ref: CustomAgentRef(
                id: "fake-acp",
                displayName: "Fake ACP",
                transport: .agentClientProtocol,
                executablePath: fakeBin.path,
                arguments: []
            ),
            environment: env,
            fileSystem: fs,
            clock: SystemClock(),
            random: SystemRandomSource()
        )

        let sink = FakeACPEventSink()
        let sub = await engine.bus.subscribe()
        let collector = Task { await sink.ingest(sub.stream) }
        var responded: Set<UUID> = []
        let approver = Task {
            while !Task.isCancelled {
                if autoApprovePermissions,
                   let id = await sink.pendingPermissionID(excluding: responded) {
                    responded.insert(id)
                    try? await engine.send(.respondToPermission(id: id, decision: .allow))
                }
                try? await Task.sleep(for: .milliseconds(100))
            }
        }
        defer {
            approver.cancel()
            collector.cancel()
            Task { await engine.bus.unsubscribe(sub.id) }
        }

        try await engine.start(adapter: adapter, workspace: ws, resumeSessionID: resumeSessionID)

        if scenario == "authFail" {
            let sawAuth = await fakeACPPollUntil(timeout: .seconds(12)) {
                await sink.containsAuthenticationRequired()
            }
            #expect(sawAuth)
            let events = await sink.snapshot()
            await engine.shutdown(reason: .naturalExit)
            assert(events)
            return
        }

        let sawSession = await fakeACPPollUntil(timeout: .seconds(12)) {
            await sink.hasSessionStarted()
        }
        if !sawSession {
            let events = await sink.snapshot()
            Issue.record("timed out waiting for session scenario=\(scenario) events=\(events.count) tail=\(FakeACPEventSink.tail(events))")
        }
        #expect(sawSession)

        if sendPrompt {
            try await engine.send(.sendPrompt(text: prompt, attachments: []))
            let sawTurn = await fakeACPPollUntil(timeout: .seconds(12)) {
                await sink.matches(until)
            }
            if !sawTurn {
                let events = await sink.snapshot()
                Issue.record("timed out scenario=\(scenario) events=\(events.count) tail=\(FakeACPEventSink.tail(events))")
            }
            #expect(sawTurn)
        }

        let events = await sink.snapshot()
        await engine.shutdown(reason: .naturalExit)
        assert(events)
    }

    private func makeWorkspace() throws -> URL {
        let url = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("acp-ws-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    private static func locateFakeACP() -> URL? {
        let cwd = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
        let candidates = [
            cwd.appendingPathComponent(".build/debug/fake-acp"),
            cwd.appendingPathComponent(".build/arm64-apple-macosx/debug/fake-acp"),
        ]
        return candidates.first { FileManager.default.isExecutableFile(atPath: $0.path) }
    }
}

private actor FakeACPEventSink {
    private var events: [AgentEvent] = []

    func ingest(_ stream: AsyncStream<MulticastEventBus.HistoryEntry>) async {
        for await entry in stream {
            events.append(entry.event)
            if events.count > 512 { break }
        }
    }

    func snapshot() -> [AgentEvent] { events }

    func hasSessionStarted() -> Bool {
        events.contains {
            if case .sessionStarted(let id, _, _) = $0 { return !id.isEmpty }
            return false
        }
    }

    func containsAuthenticationRequired() -> Bool {
        events.contains { if case .error(.authenticationRequired) = $0 { return true }; return false }
    }

    func matches(_ predicate: @Sendable ([AgentEvent]) -> Bool) -> Bool {
        predicate(events)
    }

    func pendingPermissionID(excluding responded: Set<UUID>) -> UUID? {
        for event in events {
            if case .permissionRequest(let prompt) = event, !responded.contains(prompt.id) {
                return prompt.id
            }
        }
        return nil
    }

    static func tail(_ events: [AgentEvent]) -> String {
        events.suffix(6).map { String(describing: $0) }.joined(separator: " | ")
    }
}

private extension Array where Element == AgentEvent {
    func containsFinalAssistantText(containing substring: String) -> Bool {
        contains {
            if case .assistantText(_, _, let text, true) = $0 {
                return text.localizedCaseInsensitiveContains(substring)
            }
            return false
        }
    }

    func containsPermissionRequest() -> Bool {
        contains { if case .permissionRequest = $0 { return true }; return false }
    }

    func containsAuthenticationRequired() -> Bool {
        contains { if case .error(.authenticationRequired) = $0 { return true }; return false }
    }
}

private func fakeACPPollUntil(timeout: Duration,
                              _ condition: @Sendable () async -> Bool) async -> Bool {
    let deadline = ContinuousClock.now + timeout
    while ContinuousClock.now < deadline {
        if await condition() { return true }
        try? await Task.sleep(for: .milliseconds(100))
    }
    return await condition()
}
