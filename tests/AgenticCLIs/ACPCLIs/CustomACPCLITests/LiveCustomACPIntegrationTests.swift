import Foundation
import Testing
@testable import ACPCLIs
import AgentCore
import AgentTestSupport

@Suite("AgentEngine + CustomACPAdapter live harness")
struct LiveCustomACPIntegrationTests {

    @Test("live custom ACP session responds to a prompt")
    func livePrompt() async throws {
        guard LiveCustomACPHarness.isEnabled() else {
            return
        }
        guard let exe = LiveCustomACPHarness.executablePath() else {
            Issue.record("Set CODEMIXER_LIVE_ACP_BIN to a real ACP binary")
            return
        }

        let ws = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("live-custom-acp-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: ws, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: ws) }

        let result = try await LiveCustomACPHarness().run(.init(
            workspace: ws,
            executablePath: exe
        ))
        #expect(result.sessionID != nil)
        #expect(result.finalAssistantText?.contains("codemixer-custom-acp-pong") == true)
    }

    @Test("live migration reflection surfaces dashboard file sessions attention and full pipeline")
    func liveMigrationReflection() async throws {
        guard LiveCustomACPHarness.isMigrationPipelineEnabled() else {
            return
        }
        guard let exe = LiveCustomACPHarness.executablePath() else {
            Issue.record("Set CODEMIXER_LIVE_ACP_BIN to migration-tool/dist/migration-acp")
            return
        }
        guard FileManager.default.isExecutableFile(atPath: exe) else {
            Issue.record("CODEMIXER_LIVE_ACP_BIN is not executable: \(exe)")
            return
        }

        let ws = TestPaths.temporaryRoot
            .appendingPathComponent("codemixer-live-migration-\(UUID().uuidString)", isDirectory: true)

        let result = try await LiveCustomACPHarness().runMigrationReflection(.init(
            workspace: ws,
            executablePath: exe
        ))

        #expect(result.dashboardURL.host == "127.0.0.1" || result.dashboardURL.host == "localhost")
        #expect(result.controlSessionID != nil)
        #expect(result.fileSessionIDs.count >= 2)
        #expect(result.sessionIndexChangedCount > 0)
        #expect(result.attentionRaisedCount > 0 || result.permissionResolvedCount > 0)
        #expect(result.runState == "complete")
        #expect(result.everyFileVerified)
        #expect(result.everyFileHadFixer)
        #expect(result.allRolesPresent)
        #expect(result.filesMissingRoles.isEmpty)

        // Keep workspace for optional GUI open: print path on success.
        print("CODEMIXER_LIVE_MIGRATION_WORKSPACE=\(ws.path)")
        print("CODEMIXER_LIVE_MIGRATION_DASHBOARD=\(result.dashboardURL.absoluteString)")
        print("CODEMIXER_LIVE_MIGRATION_FILE_SESSIONS=\(result.fileSessionIDs.joined(separator: ","))")
    }
}
