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

    /// Server-global pairing state. `attemptCount` resets on every fresh PIN;
    /// a lockout discards the PIN outright, so a locked-out server has no
    /// PIN to fall back on once `until` passes — the next attempt sees
    /// `.unpaired` and reports `.expiredPIN`, not a renewed chance at the
    /// old PIN. `paired` devices are tracked separately: once paired, a
    /// device's token survives PIN churn.
    enum AuthState: Sendable, Equatable {
        case unpaired
        case awaitingPIN(pin: String, expiresAt: Date, attemptCount: Int)
        case lockedOut(until: Date)
    }

    private static let pinTTL = RemoteAuthTiming.pinTTL
    private static let lockoutSeconds = RemoteAuthTiming.lockoutSeconds
    private static let minAttemptInterval = RemoteAuthTiming.minAttemptInterval
    private static let maxAttempts = RemoteAuthTiming.maxAttempts

    private let clock: any AgentClock
    private let random: any RandomSource
    private var state: AuthState = .unpaired
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
        state = .awaitingPIN(pin: pin,
                             expiresAt: clock.now().addingTimeInterval(Self.pinTTL),
                             attemptCount: 0)
        lastAttemptAt = nil
        return pin
    }

    public func attemptPair(pin candidate: String, deviceName: String) -> PairOutcome {
        let now = clock.now()
        if case .lockedOut(let until) = state, until > now {
            return .lockedOut
        }
        guard case .awaitingPIN(let pin, let expiresAt, let attemptCount) = state else {
            return .expiredPIN
        }
        if expiresAt < now {
            state = .unpaired
            return .expiredPIN
        }
        if let lastAttemptAt, now.timeIntervalSince(lastAttemptAt) < Self.minAttemptInterval {
            return .rateLimited
        }
        lastAttemptAt = now

        if constantTimeEqual(candidate, pin) {
            let token = random.bytes(32).base64EncodedString()
            let device = PairedDevice(token: token,
                                      deviceName: deviceName,
                                      pairedAt: now,
                                      lastSeen: now)
            paired[token] = device
            state = .unpaired
            lastAttemptAt = nil
            if let store {
                Task { await store.save(device) }
            }
            return .success(token: token, deviceName: deviceName)
        }

        let nextAttemptCount = attemptCount + 1
        if nextAttemptCount >= Self.maxAttempts {
            state = .lockedOut(until: now.addingTimeInterval(Self.lockoutSeconds))
            return .lockedOut
        }
        state = .awaitingPIN(pin: pin, expiresAt: expiresAt, attemptCount: nextAttemptCount)
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
