import Foundation
import Testing
@testable import AgentCore
@testable import AgentProtocol
@testable import AgentRemoteControl
import AgentTestSupport

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
        let expected = AgentCommandFixtures.dispatchParitySamples()

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
