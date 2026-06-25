import Foundation
import Testing
@testable import AgentRemoteControl
@testable import AgentCore
import AgentTestSupport

@Suite("LiveNetworkTransport — TLS loopback", .serialized)
struct LiveTLSTransportTests {

    @Test("TLS server and fingerprint-pinned client exchange bytes over loopback")
    func tlsLoopbackRoundTrip() async throws {
        try #require(FileManager.default.isExecutableFile(atPath: SystemPaths.openssl.path))

        let home = FileManager.default.temporaryDirectory
            .appendingPathComponent("codemixer-live-tls-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: home) }

        let service = "com.codecave.Codemixer.tests.liveTLS.\(UUID().uuidString)"
        let keychain = KeychainStore()
        defer { Task { await keychain.deleteAll(service: service) } }

        let cert = try await CertificateManager(
            environment: FakeEnvironment(home: home),
            keychain: keychain,
            passwordService: service,
            passwordAccount: "default"
        ).loadOrCreate()

        let transport = LiveNetworkTransport()
        let listener = try await transport.listen(
            on: .loopback(port: 0),
            options: NetworkOptions(kind: .tcp, tls: .server(identity: cert.identity))
        )
        defer { Task { await listener.cancel() } }

        let serverTask = Task<Data?, Never> {
            for await connection in listener.connections {
                let data = try? await connection.receive()
                try? await connection.send(Data("secure-pong".utf8))
                await connection.close()
                return data
            }
            return nil
        }

        let client = try await transport.connect(
            to: .loopback(port: listener.port),
            options: NetworkOptions(kind: .tcp, tls: .pinnedFingerprint(cert.sha256Fingerprint))
        )
        try await client.send(Data("secure-ping".utf8))
        let reply = try await client.receive()
        await client.close()

        let received = await withTaskGroup(of: Data?.self) { group in
            group.addTask { await serverTask.value }
            group.addTask {
                try? await Task.sleep(for: .seconds(3))
                serverTask.cancel()
                return nil
            }
            let value = await group.next() ?? nil
            group.cancelAll()
            return value
        }

        #expect(reply == Data("secure-pong".utf8))
        #expect(received == Data("secure-ping".utf8))
    }
}
