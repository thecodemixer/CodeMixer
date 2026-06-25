import Foundation
import Testing
@testable import ClaudeCode
import AgentCore
import AgentProtocol

@Suite("ClaudeAdapter launch argv")
struct ClaudeAdapterLaunchArgvTests {

    @Test("launch argv stays on the interactive billing path")
    func launchArgvStaysInteractive() {
        let adapter = ClaudeAdapter()
        let context = LaunchContext(
            workspace: URL(fileURLWithPath: "/tmp/codemixer"),
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
