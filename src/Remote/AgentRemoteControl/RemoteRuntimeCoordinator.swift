import Foundation
import AgentCore

/// Shared remote-control bootstrap for the GUI app and headless daemon.
///
/// Owns pairing, certificates, WebSocket server, Bonjour, and HTTP sidecar
/// setup so entry points stay thin and identical.
public actor RemoteRuntimeCoordinator {

    public struct Configuration: Sendable {
        public var host: RemoteControlServer.BindHost
        public var requireAuth: Bool
        public var useTLS: Bool

        public init(host: RemoteControlServer.BindHost,
                    requireAuth: Bool,
                    useTLS: Bool) {
            self.host = host
            self.requireAuth = requireAuth
            self.useTLS = useTLS
        }
    }

    public private(set) var server: RemoteControlServer?
    public private(set) var sidecar: HTTPSidecarServer?
    public private(set) var bonjour: BonjourAdvertiser?
    public private(set) var certificateFingerprint: String?

    private let seams: Seams
    private let pairing: PairingService
    private let certificates: CertificateManager

    public init(seams: Seams, pairing: PairingService, certificates: CertificateManager) {
        self.seams = seams
        self.pairing = pairing
        self.certificates = certificates
    }

    public static func makePairing(seams: Seams) async -> PairingService {
        let store = PairedDeviceStore()
        let pairing = PairingService(clock: seams.clock,
                                     random: seams.random,
                                     store: store)
        await pairing.loadPersisted()
        return pairing
    }

    public static func makeCertificates(seams: Seams) -> CertificateManager {
        CertificateManager(environment: seams.environment,
                           fileSystem: seams.fileSystem,
                           random: seams.random)
    }

    @discardableResult
    public func start(engine: AgentEngine,
                      configuration: Configuration) async throws -> RemoteControlServer {
        let transport = LoggingNetworkTransport(wrapping: LiveNetworkTransport(),
                                                category: "RemoteControl.Net")
        let remote = RemoteControlServer(engine: engine,
                                         bus: engine.bus,
                                         pairing: pairing,
                                         certificates: certificates,
                                         transport: transport,
                                         random: seams.random)
        try await remote.start(configuration: .init(
            host: configuration.host,
            port: RemoteDefaults.webSocketPort,
            requireAuth: configuration.requireAuth,
            useTLS: configuration.useTLS
        ))
        certificateFingerprint = await remote.certificateFingerprint
        server = remote

        let bonjour = BonjourAdvertiser()
        try? await bonjour.start(deviceName: seams.environment.deviceName,
                                 port: RemoteDefaults.webSocketPort,
                                 pairingState: .open,
                                 certificateFingerprint: certificateFingerprint)
        self.bonjour = bonjour

        let sidecar = HTTPSidecarServer(
            attachmentsDirectory: AppSupportPaths.attachmentsDirectory(
                in: seams.environment.appSupportDirectory
            ),
            serverInfo: ServerInfo(versionLabel: "1.0.0", clientCount: 0),
            transport: LoggingNetworkTransport(wrapping: LiveNetworkTransport(),
                                               category: "HTTPSidecar.Net"),
            clock: seams.clock,
            random: seams.random,
            fileSystem: seams.fileSystem
        )
        try? await sidecar.start(configuration: .init(host: configuration.host,
                                                      port: RemoteDefaults.sidecarPort))
        self.sidecar = sidecar
        return remote
    }

    public func stop() async {
        await bonjour?.stop()
        bonjour = nil
        await sidecar?.stop()
        sidecar = nil
        await server?.stop()
        server = nil
    }
}
