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

    static func notificationContent(for event: AgentEvent) -> NotificationContent? {
        switch event {
        case .statusPhraseChanged(let source, let phrase) where source == .hookHint:
            NotificationContent(title: AppIdentity.displayName, body: phrase)
        case .sessionAttentionChanged(_, let title, let needsAttention) where needsAttention:
            NotificationContent(title: AppIdentity.displayName, body: "\(title) needs human review")
        default:
            nil
        }
    }

    /// Convenience: tail a bus and route notifications/bells.
    public func tail(bus: MulticastEventBus) async {
        let sub = await bus.subscribe()
        for await entry in sub.stream {
            switch entry.event {
            case .bell:
                bell()
            default:
                if let content = Self.notificationContent(for: entry.event) {
                    notify(title: content.title, body: content.body)
                }
            }
        }
    }

    struct NotificationContent: Equatable {
        let title: String
        let body: String
    }
}
