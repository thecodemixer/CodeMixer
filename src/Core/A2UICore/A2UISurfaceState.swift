import AgentProtocol
import Foundation

/// Canonical, generation-keyed reduction of one A2UI surface. This is the
/// single source of truth persisted durably and projected into the SwiftUI
/// renderer.
public struct A2UISurfaceState: Sendable, Hashable, Codable {
    public let surfaceID: String
    public let agentID: String
    public let catalogID: String
    public let theme: A2UITheme?
    public let sendDataModel: Bool
    public let generation: Int
    public private(set) var components: [String: A2UIComponent]
    public private(set) var dataModel: A2UIDataDocument
    public private(set) var sensitivePaths: Set<String>
    public let createdAt: Date
    public private(set) var updatedAt: Date

    public init(surfaceID: String,
                agentID: String,
                catalogID: String,
                theme: A2UITheme?,
                sendDataModel: Bool,
                generation: Int,
                createdAt: Date) {
        self.surfaceID = surfaceID
        self.agentID = agentID
        self.catalogID = catalogID
        self.theme = theme
        self.sendDataModel = sendDataModel
        self.generation = generation
        components = [:]
        dataModel = .empty
        sensitivePaths = []
        self.createdAt = createdAt
        updatedAt = createdAt
    }

    public var rootComponentID: String? {
        components["root"] != nil ? "root" : nil
    }

    public var isRenderable: Bool { rootComponentID != nil }

    mutating func replaceComponents(_ items: [A2UIComponent], at date: Date) {
        let stored: [A2UIComponent]
        if A2UICatalog.isKnownCatalogID(catalogID) {
            stored = items
        } else {
            stored = items.map { component in
                if case .unknown = component.body { return component }
                return A2UIComponent(
                    id: component.id,
                    body: .unknown(A2UIOpaqueComponent(kindName: component.body.wireKindName,
                                                       raw: A2UIOpaqueJSON(component.jsonValue))),
                    weight: component.weight,
                    accessibility: component.accessibility
                )
            }
        }
        for item in stored {
            components[item.id] = item
        }
        recomputeSensitivePaths()
        updatedAt = date
    }

    mutating func setDataModel(path: A2UIJSONPointerPath, value: A2UIResolvedValue?, at date: Date) {
        dataModel = A2UIJSONPointer.setting(at: path.rawValue, to: value, in: dataModel)
        updatedAt = date
    }

    private mutating func recomputeSensitivePaths() {
        var paths: Set<String> = []
        for component in components.values {
            guard case .textField(let props) = component.body,
                  props.variant?.isObscured == true,
                  case .binding(let binding)? = props.value else { continue }
            paths.insert(binding.path)
        }
        sensitivePaths = paths
    }

    public func redactedDataModel() -> A2UIDataDocument {
        var redacted = dataModel
        for path in sensitivePaths {
            redacted = A2UIJSONPointer.setting(at: path, to: .string("•••"), in: redacted)
        }
        return redacted
    }

    public func synthesizedReplayMessages() -> [A2UIServerMessage] {
        var messages: [A2UIServerMessage] = [.createSurface(surfaceID: surfaceID, catalogID: catalogID, theme: theme,
                                                            sendDataModel: sendDataModel)]
        if !components.isEmpty {
            messages.append(.updateComponents(surfaceID: surfaceID,
                                              components: components.values.sorted { $0.id < $1.id }))
        }
        if !dataModel.isEmptyObject {
            messages.append(.updateDataModel(surfaceID: surfaceID, path: A2UIJSONPointerPath(""), value: A2UIResolvedValue(json: dataModel.json)))
        }
        return messages
    }
}
