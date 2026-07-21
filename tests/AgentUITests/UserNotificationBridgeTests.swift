import Testing
@testable import AgentCore
@testable import AgentUI

/// Verifies generic notification copy without invoking UserNotifications.framework.
@Suite("User notification bridge")
@MainActor
struct UserNotificationBridgeTests {

    @Test("hook hint notification uses the Codemixer product identity")
    func hookHintNotificationUsesProductIdentity() {
        let content = UserNotificationBridge.notificationContent(
            for: .statusPhraseChanged(source: .hookHint, phrase: "Review ready")
        )

        #expect(content?.title == AppIdentity.displayName)
        #expect(content?.body == "Review ready")
    }

    @Test("attention notification uses the Codemixer product identity")
    func attentionNotificationUsesProductIdentity() {
        let content = UserNotificationBridge.notificationContent(
            for: .sessionAttentionChanged(
                sessionID: "background",
                title: "Background review",
                needsAttention: true
            )
        )

        #expect(content?.title == AppIdentity.displayName)
        #expect(content?.body == "Background review needs human review")
    }

    @Test("cleared session attention produces no notification")
    func clearedAttentionProducesNoNotification() {
        let content = UserNotificationBridge.notificationContent(
            for: .sessionAttentionChanged(
                sessionID: "background",
                title: "Background review",
                needsAttention: false
            )
        )

        #expect(content == nil)
    }
}
