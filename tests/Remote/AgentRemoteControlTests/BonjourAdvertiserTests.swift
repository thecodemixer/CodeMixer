import Testing
import Foundation
@testable import AgentRemoteControl

@Suite("BonjourAdvertiser — TXT record policy")
struct BonjourAdvertiserTests {
    @Test("PairingState rawValues are stable")
    func pairingStateRaw() {
        #expect(BonjourAdvertiser.PairingState.open.rawValue == "open")
        #expect(BonjourAdvertiser.PairingState.paired.rawValue == "paired")
    }
}
