import Foundation
import Testing
@testable import AgentUI

/// Verifies the navigation boundary used by embedded agent dashboards.
@Suite("Loopback dashboard URL policy")
struct LoopbackDashboardURLPolicyTests {

    @Test("loopback HTTP(S) URLs are allowed")
    func loopbackURLsAllowed() {
        #expect(LoopbackDashboardURLPolicy.allowsNavigation(
            to: URL(string: "http://127.0.0.1:8422/dashboard")
        ))
        #expect(LoopbackDashboardURLPolicy.allowsNavigation(
            to: URL(string: "https://[::1]:8422/dashboard")
        ))
        #expect(LoopbackDashboardURLPolicy.allowsNavigation(
            to: URL(string: "http://localhost:8422/dashboard")
        ))
    }

    @Test("redirects outside loopback are rejected")
    func nonLoopbackURLsRejected() {
        #expect(!LoopbackDashboardURLPolicy.allowsNavigation(
            to: URL(string: "https://dashboard.example.com")
        ))
        #expect(!LoopbackDashboardURLPolicy.allowsNavigation(
            to: URL(string: "file:///tmp/dashboard.html")
        ))
        #expect(!LoopbackDashboardURLPolicy.allowsNavigation(to: nil))
    }
}
