import Foundation

import AgentCore

/// Workspace-sandboxed filesystem access for ACP reverse `fs/*` RPCs.
public struct ACPFileAccess: Sendable {
    private let workspace: URL
    private let fileSystem: any FileSystem

    public init(workspace: URL, fileSystem: any FileSystem) {
        self.workspace = workspace.standardizedFileURL
        self.fileSystem = fileSystem
    }

    public func read(id: JSONValue, params: JSONValue) async -> ACPEventDecoder.Batch {
        guard let path = params["path"]?.stringValue else {
            return error(id: id, message: "missing path")
        }
        do {
            let url = try resolve(path)
            let data = try fileSystem.readData(at: url)
            var text = String(decoding: data, as: UTF8.self)
            let lines = text.split(separator: "\n", omittingEmptySubsequences: false)
            if let line = params["line"]?.numberValue.map(Int.init) {
                let start = max(0, line - 1)
                if let limit = params["limit"]?.numberValue.map(Int.init) {
                    let end = min(lines.count, start + limit)
                    text = lines[start..<end].joined(separator: "\n")
                } else if start < lines.count {
                    text = lines[start...].joined(separator: "\n")
                } else {
                    text = ""
                }
            }
            return ACPEventDecoder.Batch(replies: [
                ACPRPCCodec.response(
                    id: id,
                    result: .object([
                        "content": .string(text),
                        "totalLines": .number(Double(lines.count)),
                    ])
                ),
            ])
        } catch let error as ACPAgentError {
            return self.error(id: id, message: error.detail)
        } catch {
            return self.error(id: id, message: String(describing: error))
        }
    }

    public func write(id: JSONValue, params: JSONValue) async -> ACPEventDecoder.Batch {
        guard let path = params["path"]?.stringValue,
              let content = params["content"]?.stringValue else {
            return error(id: id, message: "missing path or content")
        }
        do {
            let url = try resolve(path)
            let parent = url.deletingLastPathComponent()
            try fileSystem.createDirectory(at: parent, withIntermediates: true)
            try fileSystem.writeAtomically(Data(content.utf8), to: url)
            return ACPEventDecoder.Batch(replies: [
                ACPRPCCodec.response(id: id, result: .object([:])),
            ])
        } catch let error as ACPAgentError {
            return self.error(id: id, message: error.detail)
        } catch {
            return self.error(id: id, message: String(describing: error))
        }
    }

    private func resolve(_ path: String) throws -> URL {
        let url = URL(fileURLWithPath: path).standardizedFileURL
        let root = workspace.path
        guard url.path == root || url.path.hasPrefix(root.hasSuffix("/") ? root : root + "/") else {
            throw ACPAgentError.pathOutsideWorkspace(path: path)
        }
        return url
    }

    private func error(id: JSONValue, message: String) -> ACPEventDecoder.Batch {
        ACPEventDecoder.Batch(replies: [
            ACPRPCCodec.errorResponse(id: id, code: -32000, message: message),
        ])
    }
}
