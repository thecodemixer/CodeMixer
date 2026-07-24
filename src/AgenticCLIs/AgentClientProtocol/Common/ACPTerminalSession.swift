import Foundation
import AgentProtocol

import AgentCore

/// Tracks ACP reverse-terminal sessions (`terminal/*` RPCs).
public actor ACPTerminalSession {
    private struct Entry {
        let process: ACPTerminalProcess
    }

    private var terminals: [String: Entry] = [:]
    private let random: any RandomSource
    private let workspace: URL

    public init(workspace: URL, random: any RandomSource) {
        self.workspace = workspace
        self.random = random
    }

    public func create(id: JSONValue, params: JSONValue) async -> ACPEventDecoder.Batch {
        guard let command = params["command"]?.stringValue else {
            return error(id: id, message: "missing command")
        }
        let args = params["args"]?.arrayValue?.compactMap(\.stringValue) ?? []
        let cwdPath = params["cwd"]?.stringValue ?? workspace.path
        let cwd = URL(fileURLWithPath: cwdPath)
        var env: [String: String]?
        if let envVars = params["env"]?.arrayValue {
            var merged: [String: String] = [:]
            for item in envVars {
                if let name = item["name"]?.stringValue,
                   let value = item["value"]?.stringValue {
                    merged[name] = value
                }
            }
            env = merged.isEmpty ? nil : merged
        }
        let limit = params["outputByteLimit"]?.numberValue.map(Int.init) ?? 1_000_000
        let terminalID = random.uuid().uuidString
        let process = ACPTerminalProcess(outputByteLimit: limit)
        do {
            let exe = URL(fileURLWithPath: command)
            do {
                try await process.start(executable: exe, arguments: args, cwd: cwd, environment: env)
            } catch {
                try await process.start(
                    executable: URL(fileURLWithPath: "/bin/sh"),
                    arguments: ["-c", ([command] + args).map { shellEscape($0) }.joined(separator: " ")],
                    cwd: cwd,
                    environment: env
                )
            }
            terminals[terminalID] = Entry(process: process)
            return ACPEventDecoder.Batch(replies: [
                ACPRPCCodec.response(
                    id: id,
                    result: .object(["terminalId": .string(terminalID)])
                ),
            ])
        } catch {
            return self.error(id: id, message: String(describing: error))
        }
    }

    private func shellEscape(_ value: String) -> String {
        "'\(value.replacingOccurrences(of: "'", with: "'\\''"))'"
    }

    public func output(id: JSONValue, params: JSONValue) async -> ACPEventDecoder.Batch {
        guard let terminalID = params["terminalId"]?.stringValue,
              let entry = terminals[terminalID] else {
            return error(id: id, message: "terminal not found")
        }
        let snap = await entry.process.snapshot()
        return ACPEventDecoder.Batch(replies: [
            ACPRPCCodec.response(
                id: id,
                result: .object([
                    "output": .string(snap.output),
                    "truncated": .bool(snap.truncated),
                    "exitCode": snap.exitCode.map { .number(Double($0)) } ?? .null,
                ])
            ),
        ])
    }

    public func waitForExit(id: JSONValue, params: JSONValue) async -> ACPEventDecoder.Batch {
        guard let terminalID = params["terminalId"]?.stringValue,
              let entry = terminals[terminalID] else {
            return error(id: id, message: "terminal not found")
        }
        let code = await entry.process.waitForExit()
        return ACPEventDecoder.Batch(replies: [
            ACPRPCCodec.response(
                id: id,
                result: .object([
                    "exitCode": code.map { .number(Double($0)) } ?? .null,
                ])
            ),
        ])
    }

    public func kill(id: JSONValue, params: JSONValue) async -> ACPEventDecoder.Batch {
        guard let terminalID = params["terminalId"]?.stringValue,
              let entry = terminals[terminalID] else {
            return error(id: id, message: "terminal not found")
        }
        await entry.process.kill()
        return ACPEventDecoder.Batch(replies: [
            ACPRPCCodec.response(id: id, result: .object([:])),
        ])
    }

    public func release(id: JSONValue, params: JSONValue) async -> ACPEventDecoder.Batch {
        guard let terminalID = params["terminalId"]?.stringValue else {
            return error(id: id, message: "terminal not found")
        }
        if let entry = terminals.removeValue(forKey: terminalID) {
            await entry.process.release()
        }
        return ACPEventDecoder.Batch(replies: [
            ACPRPCCodec.response(id: id, result: .object([:])),
        ])
    }

    private func error(id: JSONValue, message: String) -> ACPEventDecoder.Batch {
        ACPEventDecoder.Batch(replies: [
            ACPRPCCodec.errorResponse(id: id, code: -32000, message: message),
        ])
    }
}
