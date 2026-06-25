import Foundation
import Testing
@testable import AgentUI

/// Wrapper boundary: `UserNotifications.UNUserNotificationCenter` + `NSSound`.
///
/// `UNUserNotificationCenter.current()` crashes hard inside the SwiftPM
/// test runner (no bundle proxy). We still cover the path that doesn't
/// touch UserNotifications.framework — the bell — and rely on integration
/// at app/daemon launch for the rest.
@MainActor
@Suite("SystemNotifications")
struct SystemNotificationsTests {

    @Test("bell() does not throw")
    func bellSafe() {
        let notifications = SystemNotifications()
        notifications.bell()
    }
}
