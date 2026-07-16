import Foundation
import Network
import AgentCore

/// Advertise the Codemixer service on the local network.
///
/// Thin policy layer on top of `BonjourBroadcaster` — translates
/// `(deviceName, port, pairingState, certificateFingerprint)` into a TXT
/// record and forwards to the broadcaster. The broadcaster is the wrapper for
/// `Network.NWListener`; this file does not import nor instantiate it.
///
/// Service type is `_codemixer._tcp.local.`. TXT record carries the wire
/// version, the device's display name, and current pairing state so clients
/// can decide whether a fresh PIN exchange is required.
public actor BonjourAdvertiser {

    public enum PairingState: String, Sendable { case open, paired }

    private let broadcaster: BonjourBroadcaster

    public init(broadcaster: BonjourBroadcaster = BonjourBroadcaster()) {
        self.broadcaster = broadcaster
    }

    /// Begin advertising on `port`. Idempotent — calling twice replaces the
    /// current advertisement.
    public func start(deviceName: String,
                      port: UInt16,
                      pairingState: PairingState,
                      certificateFingerprint: String? = nil) async throws {
        try await start(deviceName: deviceName,
                        port: NWEndpoint.Port(integerLiteral: port),
                        pairingState: pairingState,
                        certificateFingerprint: certificateFingerprint)
    }

    /// Begin advertising on `port`. Idempotent — calling twice replaces the
    /// current advertisement.
    public func start(deviceName: String,
                      port: NWEndpoint.Port,
                      pairingState: PairingState,
                      certificateFingerprint: String? = nil) async throws {
        var txt: [String: String] = [
            "v": RemoteDefaults.bonjourTXTVersion,
            "device": deviceName,
            "pairingState": pairingState.rawValue,
        ]
        if let fp = certificateFingerprint { txt["fp"] = fp }

        try await broadcaster.start(
            BonjourBroadcaster.Configuration(serviceType: RemoteDefaults.bonjourServiceType,
                                             name: RemoteDefaults.bonjourServiceName,
                                             port: port.rawValue,
                                             txt: txt))
    }

    public func stop() async {
        await broadcaster.stop()
    }
}
