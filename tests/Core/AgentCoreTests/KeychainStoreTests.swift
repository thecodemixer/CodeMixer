import Foundation
import Testing
@testable import AgentCore

/// Wrapper boundary: `Security.SecItem*`. Each test uses a per-run unique
/// service prefix so concurrent runs (and the macOS user's actual keychain
/// state) don't collide.
@Suite("KeychainStore", .serialized)
struct KeychainStoreTests {

    private func makeService() -> String {
        "com.codecave.Codemixer.test.\(UUID().uuidString)"
    }

    @Test("Round-trip write / read / delete")
    func roundTrip() async throws {
        let store = KeychainStore()
        let service = makeService()
        defer { Task { await store.deleteAll(service: service) } }

        try await store.write(service: service, account: "a", data: Data("hello".utf8))
        let read = await store.read(service: service, account: "a")
        #expect(read == Data("hello".utf8))

        await store.delete(service: service, account: "a")
        let after = await store.read(service: service, account: "a")
        #expect(after == nil)
    }

    @Test("Missing entry returns nil")
    func missingReturnsNil() async {
        let store = KeychainStore()
        let service = makeService()
        let read = await store.read(service: service, account: "absent")
        #expect(read == nil)
    }

    @Test("enumerate returns every entry for the service")
    func enumerateAll() async throws {
        let store = KeychainStore()
        let service = makeService()
        defer { Task { await store.deleteAll(service: service) } }

        try await store.write(service: service, account: "x", data: Data("1".utf8))
        try await store.write(service: service, account: "y", data: Data("2".utf8))
        let entries = await store.enumerate(service: service)
        #expect(entries.count == 2)
        let accounts = Set(entries.map(\.account))
        #expect(accounts == ["x", "y"])
    }

    @Test("write overwrites prior value")
    func writeOverwrites() async throws {
        let store = KeychainStore()
        let service = makeService()
        defer { Task { await store.deleteAll(service: service) } }

        try await store.write(service: service, account: "a", data: Data("v1".utf8))
        try await store.write(service: service, account: "a", data: Data("v2".utf8))
        let read = await store.read(service: service, account: "a")
        #expect(read == Data("v2".utf8))
    }

    @Test("deleteAll empties the service")
    func deleteAll() async throws {
        let store = KeychainStore()
        let service = makeService()
        try await store.write(service: service, account: "a", data: Data("1".utf8))
        try await store.write(service: service, account: "b", data: Data("2".utf8))
        await store.deleteAll(service: service)
        let entries = await store.enumerate(service: service)
        #expect(entries.isEmpty)
    }
}
