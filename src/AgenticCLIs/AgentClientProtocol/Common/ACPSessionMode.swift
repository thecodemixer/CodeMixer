import Foundation

/// One ACP session mode advertised on `session/new` / `session/load`.
public struct ACPSessionMode: Sendable, Hashable, Codable {
    public let id: String
    public let name: String
    public let description: String?

    public init(id: String, name: String, description: String? = nil) {
        self.id = id
        self.name = name
        self.description = description
    }
}
