@testable import AgentClientProtocol
import AgentCore
import AgentTestSupport
import Foundation
import Testing

@Suite("ACP reverse filesystem RPC")
struct ACPFileAccessTests {

    private let workspace = TestPaths.underTemporary("acp-ws")

    @Test("read returns workspace file contents")
    func readInsideWorkspace() async throws {
        let fs = InMemoryFileSystem()
        let file = workspace.appendingPathComponent("README.md")
        try fs.writeAtomically(Data("line1\nline2\nline3".utf8), to: file)
        let access = ACPFileAccess(workspace: workspace, fileSystem: fs)
        let batch = await access.read(
            id: .number(1),
            params: .object(["path": .string(file.path)])
        )
        let reply = batch.replies.map { String(decoding: $0, as: UTF8.self) }.joined()
        #expect(reply.contains("line1"))
        #expect(reply.contains("\"totalLines\":3"))
    }

    @Test("read honors line and limit parameters")
    func readLineLimit() async throws {
        let fs = InMemoryFileSystem()
        let file = workspace.appendingPathComponent("lines.txt")
        try fs.writeAtomically(Data("a\nb\nc\nd".utf8), to: file)
        let access = ACPFileAccess(workspace: workspace, fileSystem: fs)
        let batch = await access.read(
            id: .number(2),
            params: .object([
                "path": .string(file.path),
                "line": .number(2),
                "limit": .number(2),
            ])
        )
        let reply = batch.replies.map { String(decoding: $0, as: UTF8.self) }.joined()
        #expect(reply.contains("\"content\":\"b\\nc\""))
        #expect(reply.contains("\"totalLines\":4"))
    }

    @Test("write creates files inside workspace")
    func writeInsideWorkspace() async throws {
        let fs = InMemoryFileSystem()
        let access = ACPFileAccess(workspace: workspace, fileSystem: fs)
        let target = workspace.appendingPathComponent("out.txt")
        let batch = await access.write(
            id: .number(3),
            params: .object([
                "path": .string(target.path),
                "content": .string("hello acp"),
            ])
        )
        let reply = batch.replies.map { String(decoding: $0, as: UTF8.self) }.joined()
        #expect(!reply.contains("error"))
        let data = try fs.readData(at: target)
        #expect(String(decoding: data, as: UTF8.self) == "hello acp")
    }

    @Test("read rejects paths outside workspace")
    func readOutsideWorkspace() async {
        let fs = InMemoryFileSystem()
        let access = ACPFileAccess(workspace: workspace, fileSystem: fs)
        let batch = await access.read(
            id: .number(4),
            params: .object(["path": .string("/etc/passwd")])
        )
        let reply = batch.replies.map { String(decoding: $0, as: UTF8.self) }.joined()
        #expect(reply.contains("path-outside-workspace") || reply.contains("error"))
    }

    @Test("decoder routes fs/read_text_file to file access")
    func decoderFSRead() async throws {
        let fixture = ACPDecoderFixture()
        let file = fixture.workspace.appendingPathComponent("src.swift")
        try fixture.fileSystem.writeAtomically(Data("let x = 1".utf8), to: file)
        let batch = await fixture.decode(.serverRequest(
            id: .number(10),
            method: "fs/read_text_file",
            params: .object(["path": .string(file.path)])
        ))
        let reply = batch.replies.map { String(decoding: $0, as: UTF8.self) }.joined()
        #expect(reply.contains("let x = 1"))
    }
    @Test("decoder routes fs/write_text_file to file access")
    func decoderFSWrite() async throws {
        let fixture = ACPDecoderFixture()
        let target = fixture.workspace.appendingPathComponent("out.txt")
        let batch = await fixture.decode(.serverRequest(
            id: .number(11),
            method: "fs/write_text_file",
            params: .object([
                "path": .string(target.path),
                "content": .string("written-by-agent"),
            ])
        ))
        let reply = batch.replies.map { String(decoding: $0, as: UTF8.self) }.joined()
        #expect(!reply.contains("error"))
        let data = try fixture.fileSystem.readData(at: target)
        #expect(String(decoding: data, as: UTF8.self) == "written-by-agent")
    }
}

@Suite("ACP reverse terminal RPC")
struct ACPTerminalSessionTests {

    @Test("terminal create output and release round trip")
    func terminalLifecycle() async throws {
        let workspace = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("acp-terminal-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: workspace, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: workspace) }
        let terminals = ACPTerminalSession(workspace: workspace, random: FakeRandomSource())
        let create = await terminals.create(
            id: .number(1),
            params: .object([
                "command": .string("/bin/echo"),
                "args": .array([.string("hello-terminal")]),
                "cwd": .string(workspace.path),
            ])
        )
        let createReply = create.replies.map { String(decoding: $0, as: UTF8.self) }.joined()
        #expect(createReply.contains("terminalId"))
        guard let terminalID = extractTerminalID(from: createReply) else {
            Issue.record("missing terminal id")
            return
        }

        let output = await terminals.output(
            id: .number(2),
            params: .object(["terminalId": .string(terminalID)])
        )
        let outputReply = output.replies.map { String(decoding: $0, as: UTF8.self) }.joined()
        #expect(outputReply.contains("hello-terminal") || outputReply.contains("truncated"))

        _ = await terminals.waitForExit(
            id: .number(3),
            params: .object(["terminalId": .string(terminalID)])
        )
        let release = await terminals.release(
            id: .number(4),
            params: .object(["terminalId": .string(terminalID)])
        )
        let releaseReply = release.replies.map { String(decoding: $0, as: UTF8.self) }.joined()
        #expect(!releaseReply.contains("error"))
    }

    @Test("terminal wait_for_exit and kill return RPC responses")
    func terminalWaitAndKill() async throws {
        let workspace = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("acp-terminal-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: workspace, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: workspace) }
        let terminals = ACPTerminalSession(workspace: workspace, random: FakeRandomSource())
        let create = await terminals.create(
            id: .number(1),
            params: .object([
                "command": .string("/bin/true"),
                "args": .array([]),
            ])
        )
        let createReply = create.replies.map { String(decoding: $0, as: UTF8.self) }.joined()
        guard let terminalID = extractTerminalID(from: createReply) else {
            Issue.record("missing terminal id")
            return
        }
        let wait = await terminals.waitForExit(
            id: .number(2),
            params: .object(["terminalId": .string(terminalID)])
        )
        let waitReply = wait.replies.map { String(decoding: $0, as: UTF8.self) }.joined()
        #expect(waitReply.contains("exitCode"))
        let kill = await terminals.kill(
            id: .number(3),
            params: .object(["terminalId": .string(terminalID)])
        )
        #expect(kill.replies.isEmpty == false)
    }

    @Test("decoder routes terminal/create to terminal session")
    func decoderTerminalCreate() async throws {
        let workspace = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("acp-terminal-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: workspace, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: workspace) }
        let fixture = ACPDecoderFixture(workspace: workspace)
        let batch = await fixture.decode(.serverRequest(
            id: .number(20),
            method: "terminal/create",
            params: .object([
                "command": .string("/bin/echo"),
                "args": .array([.string("via-decoder")]),
            ])
        ))
        let reply = batch.replies.map { String(decoding: $0, as: UTF8.self) }.joined()
        #expect(reply.contains("terminalId"))
    }

    private func extractTerminalID(from reply: String) -> String? {
        guard let range = reply.range(of: "\"terminalId\":\"") else { return nil }
        let tail = reply[range.upperBound...]
        guard let end = tail.firstIndex(of: "\"") else { return nil }
        return String(tail[..<end])
    }
}
