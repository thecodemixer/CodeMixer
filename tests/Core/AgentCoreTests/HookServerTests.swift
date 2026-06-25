import Foundation
import Testing
@testable import AgentCore
import AgentTestSupport

/// Tests for `HookServer` over the in-memory network transport.
///
/// Spawning a real Unix-domain socket listener requires no special entitlements
/// but the in-memory transport is faster and immune to port collisions.
@Suite("HookServer — request dispatch", .serialized)
struct HookServerTests {

    @Test("start() makes the server reachable; stop() finishes the requests stream")
    func startAndStop() async throws {
        let net = InMemoryNetwork()
        let server = try makeServer(transport: net.transport)

        try await server.start()
        await server.stop()
        // If we reach here without hanging, the stream finished cleanly.
    }

    @Test("Client payload with hook_event_name is decoded and yielded on requests stream")
    func requestDecoded() async throws {
        let net = InMemoryNetwork()
        let server = try makeServer(transport: net.transport)
        try await server.start()

        let payload = Data(#"{"hook_event_name":"SessionStart","session_id":"s1"}"#.utf8)
        let collectTask = Task<HookRequest?, Never> {
            for await req in server.requests { return req }
            return nil
        }

        // Connect a client and send the payload
        let conn = try await net.transport.connect(to: .unixSocket(path: server.socketPath),
                                                    options: .plainTCP)
        try await conn.send(payload)
        await conn.close()

        // Give the server a moment to read and yield.
        try await Task.sleep(for: .milliseconds(100))
        await server.stop()
        let req = await collectTask.value
        #expect(req?.eventName == "SessionStart")
    }

    @Test("Empty payload connection is discarded without yielding a request")
    func emptyPayloadDiscarded() async throws {
        let net = InMemoryNetwork()
        let server = try makeServer(transport: net.transport)
        try await server.start()

        let collector = RequestCollector()
        let collectTask = Task { await collector.collect(from: server.requests) }

        let conn = try await net.transport.connect(to: .unixSocket(path: server.socketPath),
                                                    options: .plainTCP)
        await conn.close()

        try await Task.sleep(for: .milliseconds(80))
        await server.stop()
        collectTask.cancel()

        #expect(await collector.requests.isEmpty)
    }

    @Test("respond(to:with:) sends data back on the connection and closes it")
    func respondSendsData() async throws {
        let net = InMemoryNetwork()
        let server = try makeServer(transport: net.transport)
        try await server.start()

        let payload    = Data(#"{"hook_event_name":"PreToolUse"}"#.utf8)
        let respBody   = Data(#"{"decision":"allow"}"#.utf8)

        // Race the server handler and the client send concurrently.
        // The handler must start before we close the client so it can capture
        // the response on the still-open server-side outbox.
        let handlerTask = Task<Bool, Never> {
            for await req in server.requests {
                await server.respond(to: req.id, with: respBody)
                return true
            }
            return false
        }

        // Send, then close to signal EOF — `acceptConnection` waits for EOF
        // before yielding a request, so the close is mandatory.
        let clientConn = try await net.transport.connect(to: .unixSocket(path: server.socketPath),
                                                          options: .plainTCP)
        try await clientConn.send(payload)
        await clientConn.close()

        let responded = await handlerTask.value
        #expect(responded)
        await server.stop()
    }

    @Test("makeHandle() returns a HookSocketHandle whose requests stream is the same as server.requests")
    func makeHandleMatchesStream() async throws {
        let net = InMemoryNetwork()
        let server = try makeServer(transport: net.transport)
        try await server.start()

        let handle = await server.makeHandle()
        let payload = Data(#"{"hook_event_name":"Stop"}"#.utf8)

        let conn = try await net.transport.connect(to: .unixSocket(path: server.socketPath),
                                                    options: .plainTCP)
        try await conn.send(payload)
        await conn.close()

        var first: HookRequest?
        for await req in handle.incoming { first = req; break }
        #expect(first?.eventName == "Stop")
        await server.stop()
    }

    @Test("socketPath is non-empty and ends in .sock")
    func socketPath() async throws {
        let net = InMemoryNetwork()
        let server = try makeServer(transport: net.transport)
        let path = server.socketPath
        #expect(!path.isEmpty)
        #expect(path.hasSuffix(".sock"))
    }

    // MARK: - Helpers

    private func makeServer(transport: any NetworkTransport) throws -> HookServer {
        let env = FakeEnvironment()
        let fs = InMemoryFileSystem()
        return try HookServer(environment: env, fileSystem: fs, transport: transport)
    }
}

private actor RequestCollector {
    private(set) var requests: [HookRequest] = []
    func collect(from stream: AsyncStream<HookRequest>) async {
        for await req in stream { requests.append(req) }
    }
}
