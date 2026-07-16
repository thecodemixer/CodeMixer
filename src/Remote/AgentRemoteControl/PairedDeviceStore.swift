import Foundation
import OSLog
import AgentCore

/// Persists the paired-device list via `KeychainStore` so paired phones stay
/// paired across daemon restarts. The token is the secret; everything else
/// (display name, paired-at, last-seen) rides as a JSON blob in the entry's
/// data field.
public actor PairedDeviceStore {

    private let log = Logger(subsystem: AppIdentity.logSubsystem, category: "PairedDeviceStore")
    private let serviceID: String
    private let keychain: KeychainStore

    public init(keychain: KeychainStore = KeychainStore(),
                service: String = AppIdentity.pairedDevicesService) {
        self.keychain = keychain
        self.serviceID = service
    }

    public func loadAll() async -> [PairingService.PairedDevice] {
        let entries = await keychain.enumerate(service: serviceID)
        var devices: [PairingService.PairedDevice] = []
        var decodeFailures = 0
        for entry in entries {
            do {
                devices.append(try JSONDecoder().decode(PairingService.PairedDevice.self, from: entry.data))
            } catch {
                decodeFailures += 1
                log.warning("paired device decode failed account=\(entry.account, privacy: .public) error=\(String(describing: error), privacy: .public)")
            }
        }
        if decodeFailures > 0 {
            await SilentDiagnostics.shared.record(
                kind: .pairedDevicesQuietReset,
                owner: "PairedDeviceStore",
                summary: "dropped \(decodeFailures) unreadable paired-device record(s)",
                details: "service=\(serviceID)"
            )
        }
        return devices
    }

    public func save(_ device: PairingService.PairedDevice) async {
        guard let data = try? JSONEncoder().encode(device) else { return }
        do {
            try await keychain.write(service: serviceID,
                                     account: device.token,
                                     data: data)
        } catch {
            log.warning("paired device save failed: \(String(describing: error), privacy: .public)")
        }
    }

    public func deleteToken(_ token: String) async {
        await keychain.delete(service: serviceID, account: token)
    }
}
