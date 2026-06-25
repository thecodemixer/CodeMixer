import Foundation
import Testing
@testable import AgentRemoteControl
import AgentCore
import AgentTestSupport

@Suite("CertificateManager — TLS identity persistence", .serialized)
struct CertificateManagerTests {

    @Test("loadOrCreate generates a certificate once and reloads the same fingerprint")
    func loadOrCreateIsIdempotent() async throws {
        try #require(FileManager.default.isExecutableFile(atPath: SystemPaths.openssl.path))

        let home = FileManager.default.temporaryDirectory
            .appendingPathComponent("codemixer-cert-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: home) }

        let service = "com.codecave.Codemixer.tests.remoteCertPassword.\(UUID().uuidString)"
        let keychain = KeychainStore()
        defer { Task { await keychain.deleteAll(service: service) } }

        let manager = CertificateManager(
            environment: FakeEnvironment(home: home),
            processRunner: ProcessRunner(),
            keychain: keychain,
            passwordService: service,
            passwordAccount: "default"
        )

        let first = try await manager.loadOrCreate()
        let second = try await manager.loadOrCreate()

        #expect(!first.sha256Fingerprint.isEmpty)
        #expect(first.sha256Fingerprint == second.sha256Fingerprint)
        #expect(first.certificateDER == second.certificateDER)
    }
}
