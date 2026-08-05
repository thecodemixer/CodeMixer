import Foundation

/// One decoded `server_to_client` A2UI message (`createSurface`,
/// `updateComponents`, `updateDataModel`, or `deleteSurface`).
///
/// `Codable` conformance mirrors the exact vendored wire shape (see
/// `A2UISchemaProfile.schemaManifest`), so this type doubles as the decode
/// target for ACP `EmbeddedResource` payloads and the Codable arm carried by
/// `AgentEvent`/`AgentEventWire` (shared type, like `PermissionPrompt`).
public enum A2UIServerMessage: Sendable, Hashable {
    case createSurface(surfaceID: String, catalogID: String, theme: A2UITheme?, sendDataModel: Bool)
    case updateComponents(surfaceID: String, components: [A2UIComponent])
    /// `path` is normalized to `"/"` when the wire message omits it (schema:
    /// "If omitted, or set to '/', refers to the entire data model").
    case updateDataModel(surfaceID: String, path: A2UIJSONPointerPath, value: A2UIResolvedValue?)
    case deleteSurface(surfaceID: String)

    public var surfaceID: String {
        switch self {
        case .createSurface(let id, _, _, _),
             .updateComponents(let id, _),
             .updateDataModel(let id, _, _),
             .deleteSurface(let id):
            return id
        }
    }
}

extension A2UIServerMessage: Codable {
    private enum RootKey: String, CodingKey {
        case version, createSurface, updateComponents, updateDataModel, deleteSurface
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.singleValueContainer()
        let root = try container.decode(JSONValue.self)
        guard case .object(let object) = root else {
            throw DecodingError.dataCorruptedError(in: container,
                                                   debugDescription: "A2UI server message must be a JSON object")
        }
        if let payload = object[RootKey.createSurface.rawValue] {
            guard let surfaceID = payload["surfaceId"]?.stringValue,
                  let catalogID = payload["catalogId"]?.stringValue else {
                throw DecodingError.dataCorruptedError(in: container,
                                                       debugDescription: "createSurface requires surfaceId and catalogId")
            }
            let theme: A2UITheme?
            if let themeJSON = payload["theme"] {
                theme = try A2UITheme(json: themeJSON)
            } else {
                theme = nil
            }
            self = .createSurface(surfaceID: surfaceID,
                                  catalogID: catalogID,
                                  theme: theme,
                                  sendDataModel: payload["sendDataModel"]?.boolValue ?? false)
        } else if let payload = object[RootKey.updateComponents.rawValue] {
            guard let surfaceID = payload["surfaceId"]?.stringValue,
                  let items = payload["components"]?.arrayValue else {
                throw DecodingError.dataCorruptedError(in: container,
                                                       debugDescription: "updateComponents requires surfaceId and components")
            }
            let components = try items.map { try A2UIComponent.decode(json: $0, allowUnknown: true) }
            self = .updateComponents(surfaceID: surfaceID, components: components)
        } else if let payload = object[RootKey.updateDataModel.rawValue] {
            guard let surfaceID = payload["surfaceId"]?.stringValue else {
                throw DecodingError.dataCorruptedError(in: container,
                                                       debugDescription: "updateDataModel requires surfaceId")
            }
            let pathRaw = payload["path"]?.stringValue ?? "/"
            let path = A2UIJSONPointerPath(pathRaw.isEmpty ? "/" : pathRaw)
            let value = payload["value"].map { A2UIResolvedValue(json: $0) }
            self = .updateDataModel(surfaceID: surfaceID, path: path, value: value)
        } else if let payload = object[RootKey.deleteSurface.rawValue] {
            guard let surfaceID = payload["surfaceId"]?.stringValue else {
                throw DecodingError.dataCorruptedError(in: container,
                                                       debugDescription: "deleteSurface requires surfaceId")
            }
            self = .deleteSurface(surfaceID: surfaceID)
        } else {
            throw DecodingError.dataCorruptedError(in: container,
                                                   debugDescription: "Unknown A2UI server message shape")
        }
    }

    public func encode(to encoder: any Encoder) throws {
        var container = encoder.singleValueContainer()
        var root: [String: JSONValue] = ["version": .string(A2UISchemaProfile.version)]
        switch self {
        case .createSurface(let surfaceID, let catalogID, let theme, let sendDataModel):
            var payload: [String: JSONValue] = ["surfaceId": .string(surfaceID),
                                                "catalogId": .string(catalogID)]
            if let theme { payload["theme"] = theme.jsonValue }
            if sendDataModel { payload["sendDataModel"] = .bool(true) }
            root["createSurface"] = .object(payload)
        case .updateComponents(let surfaceID, let components):
            root["updateComponents"] = .object([
                "surfaceId": .string(surfaceID),
                "components": .array(components.map(\.jsonValue)),
            ])
        case .updateDataModel(let surfaceID, let path, let value):
            var payload: [String: JSONValue] = ["surfaceId": .string(surfaceID),
                                                "path": .string(path.rawValue)]
            if let value { payload["value"] = value.jsonValue }
            root["updateDataModel"] = .object(payload)
        case .deleteSurface(let surfaceID):
            root["deleteSurface"] = .object(["surfaceId": .string(surfaceID)])
        }
        try container.encode(JSONValue.object(root))
    }
}
