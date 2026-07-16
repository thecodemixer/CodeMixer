import Foundation

/// One selectable model exposed by an adapter for composer / toolbar menus.
public struct AgentModelOption: Sendable, Hashable, Codable {
    public let id: String
    public let label: String

    public init(id: String, label: String) {
        self.id = id
        self.label = label
    }
}
