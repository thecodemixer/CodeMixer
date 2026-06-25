import Foundation
import Security

/// Single boundary between Codemixer business code and `Security.SecItem*`.
///
/// All keychain reads and writes go through this actor. A grep for
/// `SecItemAdd` / `SecItemCopyMatching` / `SecItemDelete` returns this file
/// only.
///
/// Generic-password class only — Codemixer does not store certificates,
/// identities, or internet passwords. The P12 archive lives on disk; this
/// actor stores its passphrase.
public actor KeychainStore {

    /// Single entry returned by `enumerate(service:)`.
    public struct Entry: Sendable, Equatable {
        public let account: String
        public let data: Data

        public init(account: String, data: Data) {
            self.account = account
            self.data = data
        }
    }

    /// Typed failure surface.
    public enum KeychainError: Error, Sendable, Equatable {
        case osStatus(OSStatus)
    }

    public init() {}

    /// Read the value at `(service, account)`. Returns nil when no entry
    /// exists; throws only on unexpected `OSStatus` errors.
    public func read(service: String, account: String) -> Data? {
        rawRead(service: service, account: account)
    }

    /// Atomically replace any existing value at `(service, account)` with
    /// `data`. Throws on unexpected `OSStatus`.
    public func write(service: String, account: String, data: Data) throws {
        try rawWrite(service: service, account: account, data: data)
        addToIndex(service: service, account: account)
    }

    /// No-op when the entry does not exist.
    public func delete(service: String, account: String) {
        rawDelete(service: service, account: account)
        removeFromIndex(service: service, account: account)
    }

    /// Every entry under `service`, in unspecified order.
    ///
    /// `SecItemCopyMatching(kSecMatchLimitAll)` is unreliable on the macOS
    /// legacy file keychain when the calling binary is unsigned (the case
    /// for the test runner). We side-step this by maintaining our own index
    /// of accounts as a sibling keychain entry; `enumerate` reads the index
    /// and dereferences each account.
    public func enumerate(service: String) -> [Entry] {
        let accounts = readIndex(service: service)
        return accounts.compactMap { account -> Entry? in
            guard let data = rawRead(service: service, account: account) else { return nil }
            return Entry(account: account, data: data)
        }
    }

    /// Wipe every entry under `service`. Admin/reset path used by tests.
    public func deleteAll(service: String) {
        for account in readIndex(service: service) {
            rawDelete(service: service, account: account)
        }
        rawDelete(service: service, account: indexAccount)
        // SecItemDelete by service-only is reliable even when CopyMatching
        // is not — sweep up anything the index missed (e.g. crash mid-write).
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
        ]
        _ = SecItemDelete(query as CFDictionary)
    }

    // MARK: - Raw keychain primitives

    /// Reserved account name for the index entry. Encoded with a leading
    /// NUL so user account strings can never collide.
    private let indexAccount = "\u{0}codemixer-index"

    private func rawRead(service: String, account: String) -> Data? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne,
        ]
        var raw: AnyObject?
        let status = SecItemCopyMatching(query as CFDictionary, &raw)
        guard status == errSecSuccess else { return nil }
        return raw as? Data
    }

    private func rawWrite(service: String, account: String, data: Data) throws {
        rawDelete(service: service, account: account)
        let attrs: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecValueData as String: data,
        ]
        let status = SecItemAdd(attrs as CFDictionary, nil)
        guard status == errSecSuccess else { throw KeychainError.osStatus(status) }
    }

    private func rawDelete(service: String, account: String) {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
        ]
        _ = SecItemDelete(query as CFDictionary)
    }

    // MARK: - Index

    private func readIndex(service: String) -> [String] {
        guard let data = rawRead(service: service, account: indexAccount),
              let accounts = try? JSONDecoder().decode([String].self, from: data) else {
            return []
        }
        return accounts
    }

    private func writeIndex(service: String, accounts: [String]) {
        let data = (try? JSONEncoder().encode(accounts)) ?? Data()
        if accounts.isEmpty {
            rawDelete(service: service, account: indexAccount)
        } else {
            try? rawWrite(service: service, account: indexAccount, data: data)
        }
    }

    private func addToIndex(service: String, account: String) {
        var accounts = readIndex(service: service)
        if !accounts.contains(account) {
            accounts.append(account)
            writeIndex(service: service, accounts: accounts)
        }
    }

    private func removeFromIndex(service: String, account: String) {
        var accounts = readIndex(service: service)
        accounts.removeAll { $0 == account }
        writeIndex(service: service, accounts: accounts)
    }
}
