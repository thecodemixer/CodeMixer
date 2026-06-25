import Foundation
import OSLog
import AgentCore

/// Manages the self-signed TLS certificate used by `RemoteControlServer`.
///
/// First-launch flow:
///   1. Use `ProcessRunner` to shell out to `SystemPaths.openssl` and generate a
///      P12 archive containing a fresh EC key + self-signed cert.
///   2. Import the P12 into a `SecIdentity` for use with `NWParameters.tls`.
///   3. Persist the P12 password via `KeychainStore` so subsequent runs can
///      re-import without prompting.
///
/// The cert's SHA-256 fingerprint is exposed for QR-code pairing — clients pin
/// it on first connect and reject any subsequent cert that doesn't match.
public actor CertificateManager {

    public enum CertificateError: Error, Sendable {
        case opensslMissing
        case opensslFailed(String)
        case importFailed(OSStatus)
        case fingerprintUnavailable
    }

    public typealias Bundle = CertificateIdentityImporter.Bundle

    private let log = Logger(subsystem: AppIdentity.logSubsystem, category: "CertificateManager")
    private let environment: any AgentEnvironment
    private let processRunner: ProcessRunner
    private let keychain: KeychainStore
    private let fileSystem: any FileSystem
    private let random: any RandomSource
    private let p12URL: URL
    private let passwordService: String
    private let passwordAccount: String

    public init(environment: any AgentEnvironment,
                processRunner: ProcessRunner = ProcessRunner(),
                keychain: KeychainStore = KeychainStore(),
                fileSystem: any FileSystem = SystemFileSystem(),
                random: any RandomSource = SystemRandomSource()) {
        self.init(environment: environment,
                  processRunner: processRunner,
                  keychain: keychain,
                  fileSystem: fileSystem,
                  random: random,
                  passwordService: AppIdentity.remoteCertificatePasswordService,
                  passwordAccount: "default")
    }

    init(environment: any AgentEnvironment,
         processRunner: ProcessRunner = ProcessRunner(),
         keychain: KeychainStore = KeychainStore(),
         fileSystem: any FileSystem = SystemFileSystem(),
         random: any RandomSource = SystemRandomSource(),
         passwordService: String,
         passwordAccount: String) {
        self.environment = environment
        self.processRunner = processRunner
        self.keychain = keychain
        self.fileSystem = fileSystem
        self.random = random
        self.p12URL = environment.appSupportDirectory.appendingPathComponent("remote-server.p12")
        self.passwordService = passwordService
        self.passwordAccount = passwordAccount
    }

    /// Load the existing identity, or generate a fresh one if none exists.
    public func loadOrCreate() async throws -> Bundle {
        let password = try await loadOrCreatePassword()

        if !fileSystem.fileExists(at: p12URL) {
            try await generateP12(at: p12URL, password: password)
        }

        do {
            return try CertificateIdentityImporter.importIdentity(p12Data: fileSystem.readData(at: p12URL),
                                                                 password: password)
        } catch CertificateIdentityImporter.ImportError.fingerprintUnavailable {
            throw CertificateError.fingerprintUnavailable
        } catch CertificateIdentityImporter.ImportError.importFailed(let status) {
            throw CertificateError.importFailed(status)
        }
    }

    /// Forget the current identity and regenerate on next call.
    public func rotate() async throws {
        try? fileSystem.remove(at: p12URL)
        await keychain.delete(service: passwordService, account: passwordAccount)
        _ = try await loadOrCreate()
    }

    // MARK: - Private

    private func generateP12(at url: URL, password: String) async throws {
        try fileSystem.createDirectory(at: url.deletingLastPathComponent(),
                                       withIntermediates: true)
        let opensslURL = SystemPaths.openssl
        guard fileSystem.fileExists(at: opensslURL) else {
            throw CertificateError.opensslMissing
        }

        let scratch = url.deletingLastPathComponent()
            .appendingPathComponent("remote-server-\(random.uuid().uuidString)")
        let keyURL  = scratch.appendingPathExtension("key")
        let certURL = scratch.appendingPathExtension("crt")
        defer {
            try? fileSystem.remove(at: keyURL)
            try? fileSystem.remove(at: certURL)
        }

        do {
            _ = try await processRunner.run(executable: opensslURL, arguments: [
                // SecPKCS12Import is more reliable with RSA P12 archives under
                // unsigned SwiftPM test runners; EC archives can trip a Security
                // framework null-key assertion before returning an OSStatus.
                "req", "-x509", "-newkey", "rsa:2048",
                "-days", "3650",
                "-nodes",
                "-subj", "/CN=Codemixer Remote",
                "-keyout", keyURL.path,
                "-out", certURL.path,
            ])

            _ = try await processRunner.run(executable: opensslURL, arguments: [
                "pkcs12", "-export",
                "-out", url.path,
                "-inkey", keyURL.path,
                "-in", certURL.path,
                "-passout", "pass:\(password)",
            ])
        } catch let error as ProcessRunner.ProcessError {
            throw CertificateError.opensslFailed(String(describing: error))
        }
    }

    private func loadOrCreatePassword() async throws -> String {
        if let existing = await keychain.read(service: passwordService, account: passwordAccount),
           let str = String(data: existing, encoding: .utf8) {
            return str
        }
        let str = makePassword()
        do {
            try await keychain.write(service: passwordService,
                                     account: passwordAccount,
                                     data: Data(str.utf8))
        } catch let error as KeychainStore.KeychainError {
            log.warning("keychain write failed: \(String(describing: error), privacy: .public)")
            switch error {
            case .osStatus(let status): throw CertificateError.importFailed(status)
            }
        }
        return str
    }

    private func makePassword() -> String {
        let alphabet = Array("ABCDEFGHJKLMNPQRSTUVWXYZ23456789")
        let bytes = random.bytes(32)
        let characters = bytes.map { alphabet[Int($0) % alphabet.count] }
        return String(characters)
    }
}
