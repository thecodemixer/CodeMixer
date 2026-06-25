import Foundation
import Testing
@testable import AgentRemoteControl
@testable import AgentCore
import AgentTestSupport

/// Tests for `PairedDeviceStore`.
///
/// These tests write to the real macOS Keychain using a unique per-run service
/// ID so they never interfere with production data and can be cleaned up after
/// each test. On CI the test runner is unsigned but the sidecar-index mechanism
/// in `KeychainStore` works around `SecItemCopyMatching` unreliability.
@Suite("PairedDeviceStore — keychain CRUD")
struct PairedDeviceStoreTests {

    private func makeStore() async -> (PairedDeviceStore, String) {
        let svc = "com.codecave.test.PairedDeviceStore.\(UUID().uuidString)"
        let store = PairedDeviceStore(service: svc)
        return (store, svc)
    }

    @Test("loadAll on empty store returns empty array")
    func emptyLoad() async {
        let (store, svc) = await makeStore()
        defer { Task { await store.purge(service: svc) } }

        let all = await store.loadAll()
        #expect(all.isEmpty)
    }

    @Test("save then loadAll returns the saved device")
    func saveAndLoad() async {
        let (store, svc) = await makeStore()
        defer { Task { await store.purge(service: svc) } }

        let device = makeFakeDevice(token: "tok-1", name: "iPhone 15")
        await store.save(device)
        let all = await store.loadAll()
        #expect(all.contains { $0.token == "tok-1" && $0.deviceName == "iPhone 15" })
    }

    @Test("deleteToken removes the entry from subsequent loadAll")
    func deleteToken() async {
        let (store, svc) = await makeStore()
        defer { Task { await store.purge(service: svc) } }

        let device = makeFakeDevice(token: "tok-del", name: "Watch")
        await store.save(device)
        await store.deleteToken("tok-del")
        let all = await store.loadAll()
        #expect(!all.contains { $0.token == "tok-del" })
    }

    @Test("Saving multiple devices returns all of them from loadAll")
    func multipleDevices() async {
        let (store, svc) = await makeStore()
        defer { Task { await store.purge(service: svc) } }

        await store.save(makeFakeDevice(token: "tok-a", name: "A"))
        await store.save(makeFakeDevice(token: "tok-b", name: "B"))
        await store.save(makeFakeDevice(token: "tok-c", name: "C"))
        let all = await store.loadAll()
        let tokens = Set(all.map(\.token))
        #expect(tokens.isSuperset(of: ["tok-a", "tok-b", "tok-c"]))
    }

    @Test("deleteToken for an unknown token is a no-op")
    func deleteUnknown() async {
        let (store, svc) = await makeStore()
        defer { Task { await store.purge(service: svc) } }

        await store.save(makeFakeDevice(token: "tok-keep", name: "Keep"))
        await store.deleteToken("tok-nonexistent")
        let all = await store.loadAll()
        #expect(all.contains { $0.token == "tok-keep" })
    }

    // MARK: - Helpers

    private func makeFakeDevice(token: String, name: String) -> PairingService.PairedDevice {
        PairingService.PairedDevice(token: token,
                                     deviceName: name,
                                     pairedAt: Date(),
                                     lastSeen: Date())
    }
}

extension PairedDeviceStore {
    /// Wipe all entries under `service` — test cleanup only.
    fileprivate func purge(service: String) async {
        let entries = await loadAll()
        for entry in entries { await deleteToken(entry.token) }
    }
}
