import Testing
@testable import ClaudeCode

@Suite("ClaudeAdapter — TUI fallback gate")
struct TUIFallbackGateTests {

    @Test("TUI fallback scrapes before hooks are active")
    func scrapesBeforeHooksAreActive() {
        #expect(shouldScrapeTUI(hooksActive: false))
    }

    @Test("TUI fallback is suppressed after hooks become active")
    func suppressesAfterHooksBecomeActive() {
        #expect(!shouldScrapeTUI(hooksActive: true))
    }
}
