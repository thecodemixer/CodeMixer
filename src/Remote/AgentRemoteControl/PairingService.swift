import Foundation
import AgentCore

/// Pairing state-machine: generates a 6-digit PIN, validates incoming pair
/// attempts (with rate-limiting + lockout), and issues bearer tokens.
public actor PairingService {

    public enum PairOutcome: Sendable, Equatable {
        case success(token: String, deviceName: String)
        case invalidPIN
        case expiredPIN
        case rateLimited
        case lockedOut
    }

    public struct PairedDevice: Sendable, Codable, Hashable, Identifiable {
        public var id: String { token }
        public let token: String
        public let deviceName: String
        public let pairedAt: Date
        public var lastSeen: Date
    }

    private struct ActivePIN {
        let value: String
        let expiresAt: Date
    }

    private struct AttemptRecord {
        var count: Int = 0
        var lockedUntil: Date?
    }

    private static let pinTTL: TimeInterval = 90
    private static let lockoutSeconds: TimeInterval = 300
    private static let minAttemptInterval: TimeInterval = 1
    private static let maxAttempts = 5

    private let clock: any AgentClock
    private let random: any RandomSource
    private var activePIN: ActivePIN?
    private var attempts: AttemptRecord = AttemptRecord()
    private var lastAttemptAt: Date?
    private var paired: [String: PairedDevice] = [:]
    private let store: PairedDeviceStore?

    public init(clock: any AgentClock, random: any RandomSource, store: PairedDeviceStore? = nil) {
        self.clock = clock
        self.random = random
        self.store = store
    }

    /// Hydrate `paired` from `store` if one was provided. Idempotent.
    public func loadPersisted() async {
        guard let store else { return }
        for device in await store.loadAll() {
            paired[device.token] = device
        }
    }

    /// Generate a fresh PIN (replaces any prior PIN). Returns the PIN itself.
    public func startNewPairing() -> String {
        let pin = random.pin(digits: 6)
        activePIN = ActivePIN(value: pin, expiresAt: clock.now().addingTimeInterval(Self.pinTTL))
        attempts = AttemptRecord()
        lastAttemptAt = nil
        return pin
    }

    public func attemptPair(pin candidate: String, deviceName: String) -> PairOutcome {
        let now = clock.now()
        if let lockedUntil = attempts.lockedUntil, lockedUntil > now {
            return .lockedOut
        }
        guard let active = activePIN else { return .expiredPIN }
        if active.expiresAt < now {
            activePIN = nil
            return .expiredPIN
        }
        if let lastAttemptAt, now.timeIntervalSince(lastAttemptAt) < Self.minAttemptInterval {
            return .rateLimited
        }
        lastAttemptAt = now

        if constantTimeEqual(candidate, active.value) {
            let token = random.bytes(32).base64EncodedString()
            let device = PairedDevice(token: token,
                                      deviceName: deviceName,
                                      pairedAt: now,
                                      lastSeen: now)
            paired[token] = device
            activePIN = nil
            attempts = AttemptRecord()
            lastAttemptAt = nil
            if let store {
                Task { await store.save(device) }
            }
            return .success(token: token, deviceName: deviceName)
        }

        attempts.count += 1
        if attempts.count >= Self.maxAttempts {
            attempts.lockedUntil = now.addingTimeInterval(Self.lockoutSeconds)
            activePIN = nil
            return .lockedOut
        }
        return .invalidPIN
    }

    public func validateToken(_ token: String) -> PairedDevice? {
        guard var device = paired[token] else { return nil }
        device.lastSeen = clock.now()
        paired[token] = device
        return device
    }

    public func revokeToken(_ token: String) {
        paired.removeValue(forKey: token)
        if let store {
            Task { await store.deleteToken(token) }
        }
    }

    public func allPaired() -> [PairedDevice] { Array(paired.values) }

    // MARK: - Private

    private func constantTimeEqual(_ a: String, _ b: String) -> Bool {
        let ab = Array(a.utf8); let bb = Array(b.utf8)
        guard ab.count == bb.count else { return false }
        var diff: UInt8 = 0
        for i in 0..<ab.count { diff |= ab[i] ^ bb[i] }
        return diff == 0
    }
}
