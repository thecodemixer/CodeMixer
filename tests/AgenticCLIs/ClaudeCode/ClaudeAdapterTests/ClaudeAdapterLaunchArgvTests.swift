import Foundation
import Testing
@testable import ClaudeCode
import AgentCore
import AgentProtocol
import AgentTestSupport

@Suite("ClaudeAdapter launch argv")
struct ClaudeAdapterLaunchArgvTests {

    @Test("launch argv stays on the interactive billing path")
    func launchArgvStaysInteractive() {
        let adapter = ClaudeAdapter()
        let context = LaunchContext(
            workspace: TestPaths.underTemporary("codemixer"),
            resumeSessionID: "session-1",
            permissionMode: .acceptEdits
        )
        let argv = adapter.buildLaunchArgv(context: context)

        #expect(argv.first == "claude")
        #expect(argv.contains("--permission-mode"))
        #expect(argv.contains("acceptEdits"))
        #expect(argv.contains("--resume"))
        #expect(argv.contains("session-1"))
        #expect(!argv.contains("--print"))
        #expect(!argv.contains("-p"))
        #expect(!argv.contains("--input-format"))
        #expect(!argv.contains("--output-format"))
        #expect(!argv.contains("stream-json"))
    }
}

@Suite("ClaudeAdapter agent modes")
struct ClaudeAdapterAgentModesTests {
    @Test("agent modes expose agent think and review for composer")
    func agentModes() {
        let modes = ClaudeAdapter().availableAgentModes()
        #expect(modes.map(\.id) == ["agent", "think", "review"])
        #expect(modes.map(\.label) == ["Agent", "Think", "Review"])
    }
}
