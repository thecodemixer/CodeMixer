import Foundation
@testable import AgentClientProtocol
import AgentCore
import AgentProtocol
import AgentTestSupport

struct ACPDecoderFixture {
    let workspace: URL
    let state: ACPClientState
    let decoder: ACPEventDecoder
    let sessionIndex: ACPSessionIndex
    let fileSystem: InMemoryFileSystem
    let clock: FakeClock
    let random: FakeRandomSource

    init(workspace: URL = URL(fileURLWithPath: "/tmp/acp-ws"),
         customAgentID: String = "test-agent",
         displayName: String = "Test Agent",
         resumeSessionID: String? = nil) {
        self.workspace = workspace
        self.fileSystem = InMemoryFileSystem()
        self.clock = FakeClock()
        self.random = FakeRandomSource()
        self.state = ACPClientState()
        let environment = FakeEnvironment()
        self.sessionIndex = ACPSessionIndex(
            environment: environment,
            fileSystem: fileSystem,
            clock: clock
        )
        self.decoder = ACPEventDecoder(
            state: state,
            sessionIndex: sessionIndex,
            fileAccess: ACPFileAccess(workspace: workspace, fileSystem: fileSystem),
            terminals: ACPTerminalSession(workspace: workspace, random: random),
            clock: clock,
            random: random
        )
        let context = LaunchContext(
            workspace: workspace,
            resumeSessionID: resumeSessionID,
            permissionMode: .default
        )
        _ = ACPInputEncoding.bootstrap(
            context: context,
            state: state,
            customAgentID: customAgentID,
            displayName: displayName
        )
    }

    func decode(_ incoming: ACPIncoming) async -> ACPEventDecoder.Batch {
        await decoder.decode(incoming)
    }

    func openSession(id: String = "session-1",
                     capabilities: JSONValue = .object(["loadSession": .bool(true)])) async -> ACPEventDecoder.Batch {
        _ = await decode(.response(
            id: .number(1),
            result: .object([
                "protocolVersion": .number(1),
                "agentCapabilities": capabilities,
                "authMethods": .array([]),
            ]),
            error: nil
        ))
        return await decode(.response(
            id: .number(2),
            result: .object(["sessionId": .string(id)]),
            error: nil
        ))
    }
}

actor ACPEventSink {
    private var events: [AgentEvent] = []

    func ingest(_ stream: AsyncStream<MulticastEventBus.HistoryEntry>) async {
        for await entry in stream {
            events.append(entry.event)
            if events.count > 512 { break }
        }
    }

    func snapshot() -> [AgentEvent] { events }
}

func acpAdapter(customAgentID: String = "test",
                executablePath: String = "/usr/bin/true",
                arguments: [String] = ["acp"]) -> ACPAdapter {
    ACPAdapter(
        ref: CustomAgentRef(
            id: customAgentID,
            displayName: "Test ACP",
            transport: .agentClientProtocol,
            executablePath: executablePath,
            arguments: arguments
        ),
        environment: FakeEnvironment(),
        fileSystem: InMemoryFileSystem(),
        clock: FakeClock(),
        random: FakeRandomSource()
    )
}
