import Foundation
import UserNotifications
import AppKit

/// Single boundary between Codemixer business code and
/// `UserNotifications.UNUserNotificationCenter` + `AppKit.NSSound`.
///
/// `UserNotificationBridge` keeps its bus-tail logic and routes bus events
/// to the wrapper.
@MainActor
public final class SystemNotifications {

    public init() {}

    /// Fire-and-forget authorization request. The system surfaces its own
    /// permission dialog on first call.
    public func requestPermission() {
        UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound]) { _, _ in }
    }

    /// System bell. Synchronous; returns immediately.
    public func bell() {
        NSSound.beep()
    }

    /// Post a banner notification immediately. No-op when authorisation has
    /// not been granted.
    public func post(title: String, body: String) {
        let content = UNMutableNotificationContent()
        content.title = title
        content.body = body
        content.sound = .default
        let request = UNNotificationRequest(identifier: UUID().uuidString,
                                            content: content,
                                            trigger: nil)
        UNUserNotificationCenter.current().add(request) { _ in }
    }
}
