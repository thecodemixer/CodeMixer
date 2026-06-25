import Foundation
import Testing
@testable import AgentCore
@testable import AgentProtocol
@testable import AgentRemoteControl

/// Parity guard for the typed input alphabet.
///
/// Every `AgentCommand` case must survive JSON decoding in `ClientConnection`
/// and arrive at the shared `AgentEngineCommandPort`. This catches drift where
/// a new command is Codable but not actually dispatchable over the remote API.
@Suite("Remote parity — AgentCommand dispatch", .serialized)
struct CommandDispatchParityTests {

    @Test("Every AgentCommand case dispatches through the remote server")
    func everyCommandDispatches() async throws {
        let net = InMemoryNetwork()
        let port = RecordingCommandPort()
        let bus = MulticastEventBus()
        let pairing = PairingService(clock: SystemClock(), random: SystemRandomSource())
        let server = RemoteControlServer(engine: port,
                                         bus: bus,
                                         pairing: pairing,
                                         transport: net.transport)
        try await server.start(configuration: .init(host: .loopback,
                                                    port: 0,
                                                    requireAuth: false,
                                                    useTLS: false))

        let client = try await net.transport.connect(
            to: .loopback(port: await server.boundPort ?? 0),
            options: .plainWebSocket
        )
        let encoder = JSONEncoder()
        let decoder = JSONDecoder()
        let expected = allCommands()

        for command in expected {
            let id = UUID()
            try await client.send(try encoder.encode(ClientFrame.command(id: id, command: command)))
            let data = try #require(try await client.receive())
            guard case .result(let resultID, true, nil) = try decoder.decode(ServerFrame.self, from: data) else {
                Issue.record("expected success result for \(command)")
                return
            }
            #expect(resultID == id)
        }

        #expect(await port.snapshot() == expected)
        await client.close()
        await server.stop()
    }

    private func allCommands() -> [AgentCommand] {
        let bubbleID = UUID(uuidString: "00000000-0000-0000-0000-000000000001")!
        let promptID = UUID(uuidString: "00000000-0000-0000-0000-000000000002")!
        let hunkID = UUID(uuidString: "00000000-0000-0000-0000-000000000003")!
        let attachment = AttachmentRef(id: "upload-1",
                                       filename: "spec.md",
                                       byteCount: 10,
                                       mimeType: "text/markdown")
        return [
            .sendPrompt(text: "hello", attachments: [attachment]),
            .cancelCurrentTurn,
            .editAndResubmitLast(targetBubbleID: bubbleID, text: "edited", attachments: []),
            .newSession,
            .compact,
            .selectModel(id: "claude-sonnet-4-5"),
            .setPermissionMode(.default),
            .toggleThinkMode(enabled: true),
            .toggleReviewMode(enabled: false),
            .runSlashCommand(name: "/review", args: ["quick"]),
            .runCustomCommand(path: ".claude/commands/release.md", args: ["v1"]),
            .respondToPermission(id: promptID, decision: .allow),
            .respondToInlinePrompt(id: promptID, text: "answer"),
            .openProject(path: "/tmp/project", resumeSessionID: "session-1"),
            .closeSession,
            .speakAssistantBubble(eventID: bubbleID, action: .play),
            .revertFile(path: "Sources/App.swift"),
            .revertHunk(path: "Sources/App.swift", hunkID: hunkID),
            .updateAutoApprovalRules([AutoApprovalRule(match: "Bash ls *", decision: .allow)]),
            .updateAppearancePref(key: .theme, value: .string("dark")),
            .requestSnapshot(.conversation),
        ]
    }
}

private actor RecordingCommandPort: AgentEngineCommandPort {
    private var commands: [AgentCommand] = []

    func send(_ command: AgentCommand) async throws {
        commands.append(command)
    }

    func snapshot() -> [AgentCommand] {
        commands
    }
}
