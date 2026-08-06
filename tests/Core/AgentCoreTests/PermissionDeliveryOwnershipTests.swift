@testable import AgentCore
import AgentProtocol
import AgentTestSupport
import Foundation
import Testing

/// A permission answer must reach the agent that raised the prompt, not
/// whichever agent happens to be active when the user (or the timeout)
/// decides. Project switches park the owner; slot teardown removes it.
@Suite("Permission delivery ownership", .serialized)
struct PermissionDeliveryOwnershipTests {

    @Test("Answering a parked agent's prompt writes to that agent's transport")
    func answerReachesParkedOwner() async throws {
        let ownerTransport = ScriptedTransport()
        let otherTransport = ScriptedTransport()
        let factory = PathRoutedTransportFactory(byPath: [:])
        let ownerWorkspace = try makeTempWorkspace(prefix: "codemixer-perm-owner")
        let otherWorkspace = try makeTempWorkspace(prefix: "codemixer-perm-other")
        defer {
            try? FileManager.default.removeItem(at: ownerWorkspace)
            try? FileManager.default.removeItem(at: otherWorkspace)
        }
        factory.bind(ownerWorkspace.path, to: ownerTransport)
        factory.bind(otherWorkspace.path, to: otherTransport)

        let ownerAdapter = RecordingMockAdapter(permissionDelivery: .writePTY(Data("owner-allow\n".utf8)))
        let engine = try await makeEngine(factory: factory.makeTransport)
        try await engine.start(adapter: ownerAdapter, workspace: ownerWorkspace)
        #expect(ownerAdapter.emit(.sessionStarted(sessionID: "owner-session",
                                                  model: nil,
                                                  cwd: ownerWorkspace)))
        try await Task.sleep(for: .milliseconds(20))
        let owner = try #require(await engine.activeKey)

        let prompt = PermissionPrompt(toolName: "Bash",
                                      summary: "ls",
                                      argumentsSummary: "{}",
                                      requestedAt: Date(timeIntervalSince1970: 0))
        #expect(ownerAdapter.emit(.permissionRequest(prompt: prompt)))
        try await Task.sleep(for: .milliseconds(40))

        await engine.parkActive()
        #expect(await engine.activeKey == nil)

        try await engine.start(adapter: RecordingMockAdapter(permissionDelivery: .writePTY(Data("other-allow\n".utf8))),
                               workspace: otherWorkspace)
        #expect(await engine.activeKey != owner)

        try await engine.send(.respondToPermission(id: prompt.id, decision: .allow))

        #expect(await ownerTransport.writtenData().contains(Data("owner-allow\n".utf8)))
        #expect(!(await otherTransport.writtenData().contains(Data("owner-allow\n".utf8))))
        #expect(!(await otherTransport.writtenData().contains(Data("other-allow\n".utf8))))
        await engine.shutdown(reason: .naturalExit)
    }

    @Test("Tearing down the owner drops its pending prompts so a later answer is a no-op")
    func teardownDropsOwnerPending() async throws {
        let ownerTransport = ScriptedTransport()
        let otherTransport = ScriptedTransport()
        let factory = PathRoutedTransportFactory(byPath: [:])
        let ownerWorkspace = try makeTempWorkspace(prefix: "codemixer-perm-gone-owner")
        let otherWorkspace = try makeTempWorkspace(prefix: "codemixer-perm-gone-other")
        defer {
            try? FileManager.default.removeItem(at: ownerWorkspace)
            try? FileManager.default.removeItem(at: otherWorkspace)
        }
        factory.bind(ownerWorkspace.path, to: ownerTransport)
        factory.bind(otherWorkspace.path, to: otherTransport)

        let ownerAdapter = RecordingMockAdapter(permissionDelivery: .writePTY(Data("owner-allow\n".utf8)))
        let engine = try await makeEngine(factory: factory.makeTransport)
        try await engine.start(adapter: ownerAdapter, workspace: ownerWorkspace)
        #expect(ownerAdapter.emit(.sessionStarted(sessionID: "owner-session",
                                                  model: nil,
                                                  cwd: ownerWorkspace)))
        try await Task.sleep(for: .milliseconds(20))
        let owner = try #require(await engine.activeKey)

        let prompt = PermissionPrompt(toolName: "Bash",
                                      summary: "ls",
                                      argumentsSummary: "{}",
                                      requestedAt: Date(timeIntervalSince1970: 0))
        #expect(ownerAdapter.emit(.permissionRequest(prompt: prompt)))
        try await Task.sleep(for: .milliseconds(40))

        await engine.shutdownSlot(owner, publishStopped: true)

        try await engine.start(adapter: RecordingMockAdapter(permissionDelivery: .writePTY(Data("other-allow\n".utf8))),
                               workspace: otherWorkspace)

        try await engine.send(.respondToPermission(id: prompt.id, decision: .allow))

        #expect(!(await otherTransport.writtenData().contains(Data("owner-allow\n".utf8))))
        #expect(!(await otherTransport.writtenData().contains(Data("other-allow\n".utf8))))
        await engine.shutdown(reason: .naturalExit)
    }

    @Test("Delivering to a torn-down owner reports agentGone instead of writing to the active agent")
    func deliveryToGoneOwnerThrows() async throws {
        let h = try await EngineHarness.make()
        let owner = try #require(await h.engine.activeKey)
        let prompt = PermissionPrompt(toolName: "Bash",
                                      summary: "ls",
                                      argumentsSummary: "{}",
                                      requestedAt: Date(timeIntervalSince1970: 0))

        await h.engine.shutdownSlot(owner, publishStopped: true)

        await #expect(throws: AgentEngine.PermissionDeliveryError.agentGone(projectPath: owner.projectPath)) {
            try await h.engine.deliverPermissionResponse(.deny,
                                                         for: prompt,
                                                         id: prompt.id,
                                                         owner: owner)
        }
        await h.shutdown()
    }

    private func makeEngine(factory: @escaping AgentTransportFactory) async throws -> AgentEngine {
        let fs = InMemoryFileSystem()
        let home = try makeTempWorkspace(prefix: "codemixer-perm-home")
        let env = FakeEnvironment(home: home)
        let seams = Seams.fake(environment: env, fileSystem: fs)
        let engine = AgentEngine(seams: seams, transportFactory: factory)
        await engine.bootstrap()
        return engine
    }

    private func makeTempWorkspace(prefix: String) throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("\(prefix)-\(SystemRandomSource().uuid().uuidString)",
                                    isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }
}

/// Hands each project path the transport registered for it so a pool of
/// runtimes can be driven without sharing one `ScriptedTransport`.
final class PathRoutedTransportFactory: @unchecked Sendable {
    private let lock = NSLock()
    private var byPath: [String: ScriptedTransport]

    init(byPath: [String: ScriptedTransport]) {
        self.byPath = byPath
    }

    func bind(_ path: String, to transport: ScriptedTransport) {
        let key = URL(fileURLWithPath: path).standardizedFileURL.path
        lock.lock()
        byPath[key] = transport
        lock.unlock()
    }

    func makeTransport(_ descriptor: AgentTransportDescriptor,
                       _ launch: AgentTransportLaunchSpec) throws -> any AgentTransport {
        let key = launch.workingDirectory?.standardizedFileURL.path
        lock.lock()
        let transport = key.flatMap { byPath[$0] }
        lock.unlock()
        guard let transport else {
            throw AgentTransportError.launchFailed(detail: "no transport bound for \(key ?? "<nil>")")
        }
        return transport
    }
}
