import Foundation
import Testing
@testable import AgentRemoteControl
import AgentTestSupport

@Suite("PairingService — PIN exchange and lockout")
struct PairingServiceTests {

    @Test("Correct PIN yields a paired device and a bearer token")
    func happyPath() async {
        let clock = FakeClock()
        let random = FakeRandomSource(pins: ["654321"])
        let service = PairingService(clock: clock, random: random)
        let pin = await service.startNewPairing()
        #expect(pin == "654321")

        let outcome = await service.attemptPair(pin: "654321", deviceName: "iPhone")
        guard case .success(let token, let name) = outcome else {
            #expect(Bool(false), "expected success, got \(outcome)"); return
        }
        #expect(!token.isEmpty)
        #expect(name == "iPhone")
        #expect(await service.validateToken(token)?.deviceName == "iPhone")
    }

    @Test("Five wrong PINs trigger a lockout that returns .lockedOut")
    func lockout() async {
        let clock = FakeClock()
        let random = FakeRandomSource(pins: ["111111"])
        let service = PairingService(clock: clock, random: random)
        _ = await service.startNewPairing()
        for _ in 0..<5 {
            _ = await service.attemptPair(pin: "000000", deviceName: "x")
            clock.advance(by: .seconds(1))
        }
        let outcome = await service.attemptPair(pin: "111111", deviceName: "x")
        if case .lockedOut = outcome {
            #expect(Bool(true))
        } else {
            #expect(Bool(false), "expected lockout, got \(outcome)")
        }
    }

    @Test("Wrong PIN before max attempts returns .invalidPIN")
    func invalidPIN() async {
        let clock = FakeClock()
        let random = FakeRandomSource(pins: ["123456"])
        let service = PairingService(clock: clock, random: random)
        _ = await service.startNewPairing()
        let outcome = await service.attemptPair(pin: "000000", deviceName: "x")
        #expect(outcome == .invalidPIN)
    }

    @Test("Pairing attempts faster than once per second are rate limited")
    func rateLimited() async {
        let clock = FakeClock()
        let random = FakeRandomSource(pins: ["123456"])
        let service = PairingService(clock: clock, random: random)
        _ = await service.startNewPairing()
        _ = await service.attemptPair(pin: "000000", deviceName: "x")
        let outcome = await service.attemptPair(pin: "000001", deviceName: "x")
        #expect(outcome == .rateLimited)
    }

    @Test("attemptPair after PIN TTL expires returns .expiredPIN")
    func expiredPIN() async {
        let clock = FakeClock()
        let random = FakeRandomSource(pins: ["999999"])
        let service = PairingService(clock: clock, random: random)
        _ = await service.startNewPairing()
        // Advance past the 90-second TTL
        clock.advance(by: .seconds(91))
        let outcome = await service.attemptPair(pin: "999999", deviceName: "x")
        #expect(outcome == .expiredPIN)
    }

    @Test("attemptPair with no active PIN returns .expiredPIN")
    func noActivePIN() async {
        let clock = FakeClock()
        let random = FakeRandomSource(pins: ["000000"])
        let service = PairingService(clock: clock, random: random)
        let outcome = await service.attemptPair(pin: "000000", deviceName: "x")
        #expect(outcome == .expiredPIN)
    }

    @Test("revokeToken removes the device from allPaired and validateToken returns nil")
    func revokeToken() async {
        let clock = FakeClock()
        let random = FakeRandomSource(pins: ["555555"])
        let service = PairingService(clock: clock, random: random)
        _ = await service.startNewPairing()
        let outcome = await service.attemptPair(pin: "555555", deviceName: "Tablet")
        guard case .success(let token, _) = outcome else {
            Issue.record("expected success"); return
        }
        await service.revokeToken(token)
        #expect(await service.validateToken(token) == nil)
        let all = await service.allPaired()
        #expect(!all.contains { $0.token == token })
    }

    @Test("allPaired returns all successfully paired devices")
    func allPaired() async {
        let clock = FakeClock()
        // Each pairing consumes 32 bytes for the bearer token. Provide a varying
        // sequence so the two tokens differ (the byteIndex in FakeRandomSource advances
        // across consecutive bytes() calls, giving different windows).
        let bytes: [UInt8] = Array(0..<256).map { UInt8($0) }
        let random = FakeRandomSource(pins: ["111111", "222222"], bytes: bytes)
        let service = PairingService(clock: clock, random: random)

        _ = await service.startNewPairing()
        _ = await service.attemptPair(pin: "111111", deviceName: "Phone")
        _ = await service.startNewPairing()
        _ = await service.attemptPair(pin: "222222", deviceName: "Watch")

        let all = await service.allPaired()
        #expect(all.count == 2)
        #expect(all.map(\.deviceName).contains("Phone"))
        #expect(all.map(\.deviceName).contains("Watch"))
    }

    @Test("validateToken updates lastSeen timestamp")
    func validateTokenUpdatesSeen() async {
        let clock = FakeClock()
        let random = FakeRandomSource(pins: ["777777"])
        let service = PairingService(clock: clock, random: random)
        _ = await service.startNewPairing()
        guard case .success(let token, _) = await service.attemptPair(pin: "777777", deviceName: "M") else {
            Issue.record("expected success"); return
        }
        let before = await service.validateToken(token)?.lastSeen
        clock.advance(by: .seconds(30))
        let after = await service.validateToken(token)?.lastSeen
        if let b = before, let a = after {
            #expect(a >= b)
        } else {
            Issue.record("validateToken returned nil")
        }
    }

    @Test("startNewPairing resets attempts so a prior partial-lockout is cleared")
    func startNewPairingResetsAttempts() async {
        let clock = FakeClock()
        let random = FakeRandomSource(pins: ["444444", "888888"])
        let service = PairingService(clock: clock, random: random)

        _ = await service.startNewPairing()
        for _ in 0..<4 {
            _ = await service.attemptPair(pin: "000000", deviceName: "x")
            clock.advance(by: .seconds(1))
        }

        // Fresh PIN — attempts counter should reset
        _ = await service.startNewPairing()
        let outcome = await service.attemptPair(pin: "888888", deviceName: "Clean")
        if case .success = outcome { #expect(Bool(true)) }
        else { #expect(Bool(false), "expected success after new pairing, got \(outcome)") }
    }
}
