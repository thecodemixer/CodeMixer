import Foundation
import Testing
@testable import ACPCLIs
@testable import AgentClientProtocol
import AgentCore
import AgentProtocol
import AgentTestSupport

/// Mirrors `Bootstrap.listSessions`: registry adapters + custom project factory.
@Suite("Custom ACP sidebar session listing")
struct CustomACPSessionListingTests {

    @Test("custom project sessions appear via factory resolve, not AdapterRegistry alone")
    func customSessionsListableLikeBootstrap() async throws {
        let root = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("acp-list-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let fs = SystemFileSystem()
        let ref = CustomAgentRef(
            id: "sidebar-agent",
            displayName: "Sidebar Agent",
            transport: .agentClientProtocol,
            executablePath: SystemPaths.trueBinary.path,
            arguments: []
        )
        try ProjectLocalStateStore.save(
            ProjectLocalState(displayName: "Sidebar Proj", projectType: .custom(ref)),
            to: root,
            fileSystem: fs
        )

        await CustomAgentAdapterFactories.shared.resetForTests()
        await CustomAgentAdapterFactories.shared.register(CustomACPAdapterFactory())
        defer {
            Task { await CustomAgentAdapterFactories.shared.resetForTests() }
        }

        guard let adapter = await ProjectAgentRouter.resolveAdapter(
            projectType: .custom(ref)
        ) as? CustomACPAdapter else {
            Issue.record("expected CustomACPAdapter from factory")
            return
        }

        // Seed on disk; the cached adapter's store loads the same project files.
        let store = ACPProjectSessionStore(
            customAgentID: ref.id,
            environment: FakeEnvironment(),
            fileSystem: fs,
            clock: SystemClock()
        )
        await store.recordSession(
            id: "listed-1",
            customAgentID: ref.id,
            workspace: root,
            title: "listed chat"
        )
        await store.appendConversationTurn(
            sessionID: "listed-1",
            customAgentID: ref.id,
            role: "user",
            text: "listed chat"
        )

        var registrySessions: [SessionSummary] = []
        for shipping in await AdapterRegistry.shared.all()
            where shipping.capabilities.contains(.resumableSessions) {
            registrySessions += await shipping.listResumableSessions(workspace: root)
        }
        #expect(!registrySessions.contains { $0.id == "listed-1" })

        let fromAdapter = await adapter.listResumableSessions(workspace: root)
        #expect(fromAdapter.contains { $0.id == "listed-1" && $0.title == "listed chat" })

        let combined = await listSessionsLikeBootstrap(for: root, fileSystem: fs)
        #expect(combined.contains { $0.id == "listed-1" })
    }

    /// Same algorithm as `Bootstrap.listSessions` (registry + custom project.json).
    private func listSessionsLikeBootstrap(for url: URL,
                                           fileSystem: any FileSystem) async -> [SessionSummary] {
        var sessions: [SessionSummary] = []
        var seen = Set<String>()

        func append(_ batch: [SessionSummary]) {
            for summary in batch {
                let key = "\(summary.agentID.rawValue)::\(summary.id)"
                guard seen.insert(key).inserted else { continue }
                sessions.append(summary)
            }
        }

        for adapter in await AdapterRegistry.shared.all()
            where adapter.capabilities.contains(.resumableSessions) {
            append(await adapter.listResumableSessions(workspace: url))
        }

        if let local = ProjectLocalStateStore.load(from: url, fileSystem: fileSystem),
           case .custom = local.projectType,
           let adapter = await ProjectAgentRouter.resolveAdapter(projectType: local.projectType),
           adapter.capabilities.contains(.resumableSessions) {
            append(await adapter.listResumableSessions(workspace: url))
        }

        return sessions.sorted { $0.lastActivity > $1.lastActivity }
    }
}
