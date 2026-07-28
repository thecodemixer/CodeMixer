/// Identifies one Codemixer-owned transcript independently of a live runtime.
/// The standardized project root keeps moved-through-symlink opens stable,
/// while namespace and session id keep different adapters isolated.
import Foundation

struct SessionTranscriptKey: Sendable, Codable, Hashable {
    let projectRoot: URL
    let namespace: String
    let sessionID: String

    init(projectRoot: URL, namespace: String, sessionID: String) {
        self.projectRoot = projectRoot.standardizedFileURL
        self.namespace = namespace
        self.sessionID = sessionID
    }

    var namespaceDirectoryName: String {
        Self.base64URL(namespace)
    }

    var journalFileName: String {
        Self.base64URL(sessionID) + ".jsonl"
    }

    private static func base64URL(_ value: String) -> String {
        Data(value.utf8)
            .base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }
}
