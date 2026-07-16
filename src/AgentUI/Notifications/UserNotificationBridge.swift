import Foundation
import AgentCore

/// Posts macOS user notifications for `AgentEvent.bell` and adapter
/// `Notification` events. The actual `UNUserNotificationCenter` calls live
/// behind `SystemNotifications` in `AgentUI/External/`; this file is the bus
/// policy layer.
@MainActor
public final class UserNotificationBridge {

    private let notifications: SystemNotifications

    public init(notifications: SystemNotifications = SystemNotifications()) {
        self.notifications = notifications
    }

    public func requestPermission() {
        notifications.requestPermission()
    }

    public func bell() {
        notifications.bell()
    }

    public func notify(title: String, body: String) {
        notifications.post(title: title, body: body)
    }

    /// Convenience: tail a bus and route notifications/bells.
    public func tail(bus: MulticastEventBus) async {
        let sub = await bus.subscribe()
        for await entry in sub.stream {
            switch entry.event {
            case .bell:
                bell()
            case .statusPhraseChanged(let source, let phrase) where source == .hookHint:
                notify(title: "Claude", body: phrase)
            default:
                break
            }
        }
    }
}
