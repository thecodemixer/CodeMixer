import Foundation
@testable import AgentClientProtocol
import AgentCore
import AgentProtocol
import AgentTestSupport

struct ACPDecoderFixture {
    let workspace: URL
    let state: ACPClientState
    let decoder: ACPEventDecoder
    let fileSystem: InMemoryFileSystem
    let clock: FakeClock
    let random: FakeRandomSource
    let customAgentID: String
    let metadata: SessionMetadataRecorder
    let backgroundEvents: BackgroundSessionEventRecorder

    init(workspace: URL = TestPaths.underTemporary("acp-ws"),
         customAgentID: String = "test-agent",
         displayName: String = "Test Agent",
         resumeSessionID: String? = nil) {
        self.workspace = workspace
        self.customAgentID = customAgentID
        self.fileSystem = InMemoryFileSystem()
        self.clock = FakeClock()
        self.random = FakeRandomSource()
        self.state = ACPClientState()
        let metadata = SessionMetadataRecorder()
        let backgroundEvents = BackgroundSessionEventRecorder()
        self.metadata = metadata
        self.backgroundEvents = backgroundEvents
        self.decoder = ACPEventDecoder(
            state: state,
            fileAccess: ACPFileAccess(workspace: workspace, fileSystem: fileSystem),
            terminals: ACPTerminalSession(workspace: workspace, random: random),
            clock: clock,
            random: random,
            recordBackgroundSessionEvents: { batch in
                await backgroundEvents.record(batch)
            },
            updateSessionMetadata: { update in
                await metadata.record(update)
            }
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

actor BackgroundSessionEventRecorder {
    private var batches: [BackgroundSessionEventBatch] = []

    func record(_ batch: BackgroundSessionEventBatch) {
        batches.append(batch)
    }

    func snapshot() -> [BackgroundSessionEventBatch] {
        batches
    }
}

actor SessionMetadataRecorder {
    private var updates: [SessionMetadataUpdate] = []

    func record(_ update: SessionMetadataUpdate) {
        updates.append(update)
    }

    func snapshot() -> [SessionMetadataUpdate] {
        updates
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
                executablePath: String = SystemPaths.trueBinary.path,
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
