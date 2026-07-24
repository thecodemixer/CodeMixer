import Foundation
import AgentProtocol

struct ACPSessionModes: Sendable, Equatable {
    let currentModeID: String?
    let available: [ACPSessionMode]

    static func parse(_ value: JSONValue?) -> ACPSessionModes {
        let available = (value?["availableModes"]?.arrayValue ?? []).compactMap { mode -> ACPSessionMode? in
            guard let id = mode["id"]?.stringValue, !id.isEmpty else { return nil }
            let name = mode["name"]?.stringValue.flatMap { $0.isEmpty ? nil : $0 } ?? id
            let description = mode["description"]?.stringValue.flatMap { $0.isEmpty ? nil : $0 }
            return ACPSessionMode(id: id, name: name, description: description)
        }
        return ACPSessionModes(
            currentModeID: value?["currentModeId"]?.stringValue,
            available: available
        )
    }
}
