import Foundation
import AgentProtocol

/// Resolves remote-upload attachment refs into Mac-local file paths.
///
/// The HTTP sidecar stages uploads under the app-support attachments directory
/// and returns an opaque id. The engine turns those refs into `@/path` tokens
/// before handing prompts to the adapter so the CLI still reads local files.
public actor AttachmentResolver {

    private let attachmentsDirectory: URL
    private let fileSystem: any FileSystem

    public init(environment: any AgentEnvironment,
                fileSystem: any FileSystem) {
        self.attachmentsDirectory = environment.appSupportDirectory
            .appendingPathComponent("attachments", isDirectory: true)
        self.fileSystem = fileSystem
    }

    public func resolve(_ refs: [AttachmentRef]) throws -> [URL] {
        guard !refs.isEmpty else { return [] }
        return try refs.map(resolve)
    }

    private func resolve(_ ref: AttachmentRef) throws -> URL {
        let exact = attachmentsDirectory.appendingPathComponent(ref.id)
        if fileSystem.fileExists(at: exact) {
            return exact
        }

        let candidates = try? fileSystem.contentsOfDirectory(at: attachmentsDirectory)
        if let match = candidates?
            .sorted(by: { $0.path < $1.path })
            .first(where: { $0.lastPathComponent.hasPrefix("\(ref.id)-") }) {
            return match
        }

        throw AgentError.attachmentNotFound(id: ref.id)
    }
}
