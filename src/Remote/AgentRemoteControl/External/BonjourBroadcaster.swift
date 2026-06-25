import Foundation
import Network

/// Single boundary between Codemixer business code and the Bonjour-advertising
/// path of `Network.NWListener`.
///
/// `BonjourAdvertiser` builds a `Configuration` from the
/// `(deviceName, port, pairingState, certificateFingerprint)` it gets handed,
/// then forwards it here. Direct usage of `NWListener` outside this file is
/// forbidden by `scripts/check-direct-framework-calls.swift`.
public actor BonjourBroadcaster {

    public struct Configuration: Sendable {
        public var serviceType: String
        public var name: String
        public var port: UInt16
        public var txt: [String: String]

        public init(serviceType: String, name: String, port: UInt16, txt: [String: String]) {
            self.serviceType = serviceType
            self.name = name
            self.port = port
            self.txt = txt
        }
    }

    public enum BroadcastError: Error, Sendable, Equatable {
        case listenFailed(detail: String)
    }

    private var listener: NWListener?
    private var current: Configuration?

    public init() {}

    /// Begin advertising. Replaces any in-flight advertisement.
    public func start(_ configuration: Configuration) throws {
        stop()

        let params = NWParameters.tcp
        guard let nwPort = NWEndpoint.Port(rawValue: configuration.port) else {
            throw BroadcastError.listenFailed(detail: "invalid port \(configuration.port)")
        }

        let listener: NWListener
        do {
            listener = try NWListener(using: params, on: nwPort)
        } catch {
            throw BroadcastError.listenFailed(detail: error.localizedDescription)
        }
        listener.service = NWListener.Service(name: configuration.name,
                                              type: configuration.serviceType,
                                              txtRecord: NWTXTRecord(configuration.txt))
        listener.start(queue: .global(qos: .background))
        self.listener = listener
        self.current = configuration
    }

    /// Idempotent. Safe to call before `start` or twice in a row.
    public func stop() {
        listener?.cancel()
        listener = nil
        current = nil
    }

    /// Replace the TXT record without rebinding the underlying listener.
    public func updateTXT(_ txt: [String: String]) {
        guard let listener, var config = current else { return }
        config.txt = txt
        listener.service = NWListener.Service(name: config.name,
                                              type: config.serviceType,
                                              txtRecord: NWTXTRecord(txt))
        self.current = config
    }
}
