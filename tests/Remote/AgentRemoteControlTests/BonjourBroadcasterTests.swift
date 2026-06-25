import Foundation
import Testing
@testable import AgentRemoteControl

/// Wrapper boundary: `Network.NWListener.Service` (Bonjour). We exercise the
/// lifecycle; the actual mDNS broadcast is not asserted (requires a second
/// responder on the same host).
@Suite("BonjourBroadcaster")
struct BonjourBroadcasterTests {

    @Test("start → updateTXT → stop lifecycle does not throw")
    func lifecycle() async throws {
        let broadcaster = BonjourBroadcaster()
        try await broadcaster.start(.init(serviceType: "_codemixer-test._tcp",
                                          name: "Codemixer-Test",
                                          port: 0,
                                          txt: ["v": "1"]))
        await broadcaster.updateTXT(["v": "2", "pairingState": "open"])
        await broadcaster.stop()
    }

    @Test("stop() before start() is idempotent")
    func stopBeforeStart() async {
        let broadcaster = BonjourBroadcaster()
        await broadcaster.stop()
        await broadcaster.stop()
    }
}
