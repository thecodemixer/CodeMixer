import Foundation
import Testing
@testable import AgentCore

@Suite("PTYHost — process lifecycle")
struct PTYHostTests {

    @Test("Spawning /bin/echo emits the printed text and exits cleanly")
    func echoRoundTrip() async throws {
        let spec = PTYHost.ChildSpec(
            executable: URL(fileURLWithPath: "/bin/echo"),
            arguments: ["hello-pty"],
            environment: ["TERM": "xterm-256color"],
            workingDirectory: nil
        )
        let host = try PTYHost(spec: spec)

        var collected = Data()
        let outbound = host.outboundBytes
        let collector = Task {
            for await chunk in outbound { collected.append(chunk) }
            return collected
        }

        let status = await host.exitStatus.value
        let bytes = await collector.value

        #expect(status == .exited(code: 0))
        let text = String(data: bytes, encoding: .utf8) ?? ""
        #expect(text.contains("hello-pty"))
    }

    @Test("Writing after close throws .alreadyClosed")
    func writeAfterClose() async throws {
        let spec = PTYHost.ChildSpec(
            executable: URL(fileURLWithPath: "/bin/cat"),
            arguments: [],
            environment: [:],
            workingDirectory: nil
        )
        let host = try PTYHost(spec: spec)
        await host.close()
        do {
            try await host.write(Data("x".utf8))
            #expect(Bool(false), "expected throw")
        } catch let error as PTYError {
            #expect(error == .alreadyClosed)
        }
    }

    @Test("Child exit code is decoded from wait status")
    func childExitCodeIsDecoded() async throws {
        let spec = PTYHost.ChildSpec(
            executable: URL(fileURLWithPath: "/bin/sh"),
            arguments: ["-c", "exit 3"],
            environment: [:],
            workingDirectory: nil
        )
        let host = try PTYHost(spec: spec)

        let status = await host.exitStatus.value

        #expect(status == .exited(code: 3))
    }

    @Test("Child signal termination is decoded from wait status")
    func childSignalTerminationIsDecoded() async throws {
        let spec = PTYHost.ChildSpec(
            executable: URL(fileURLWithPath: "/bin/sh"),
            arguments: ["-c", "kill -TERM $$; sleep 1"],
            environment: [:],
            workingDirectory: nil
        )
        let host = try PTYHost(spec: spec)

        let status = await host.exitStatus.value

        #expect(status == .signaled(signal: SIGTERM))
    }

    @Test("writeAllToPTY retries EINTR, EAGAIN, and partial writes")
    func writeAllRetriesTransientFailuresAndShortWrites() async throws {
        let writer = ScriptedPTYWriter()

        try await writeAllToPTY(Data("abcdef".utf8), sleep: { duration in
            #expect(duration == .milliseconds(2))
            writer.recordSleep()
        }) { chunk in
            writer.write(chunk)
        }

        #expect(writer.slept)
        #expect(writer.chunks == ["abcdef", "abcdef", "cdef", "cdef"])
    }

    @Test("writeAllToPTY throws writeFailed for hard errors")
    func writeAllThrowsHardErrors() async {
        do {
            try await writeAllToPTY(Data("x".utf8)) { _ in (-1, EBADF) }
            Issue.record("expected writeFailed")
        } catch let error as PTYError {
            #expect(error == .writeFailed(errno: EBADF))
        } catch {
            Issue.record("unexpected error: \(error)")
        }
    }
}

private final class ScriptedPTYWriter: @unchecked Sendable {
    private let lock = NSLock()
    private var calls = 0
    private var didSleep = false
    private var seenChunks: [String] = []

    var slept: Bool {
        lock.lock(); defer { lock.unlock() }
        return didSleep
    }

    var chunks: [String] {
        lock.lock(); defer { lock.unlock() }
        return seenChunks
    }

    func recordSleep() {
        lock.lock(); defer { lock.unlock() }
        didSleep = true
    }

    func write(_ chunk: Data) -> (written: Int, errno: Int32) {
        lock.lock(); defer { lock.unlock() }
        seenChunks.append(String(data: chunk, encoding: .utf8) ?? "")
        defer { calls += 1 }
        switch calls {
        case 0:
            return (-1, EINTR)
        case 1:
            return (2, 0)
        case 2:
            return (-1, EAGAIN)
        default:
            return (chunk.count, 0)
        }
    }
}
