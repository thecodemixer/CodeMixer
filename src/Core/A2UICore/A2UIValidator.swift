import AgentProtocol
import Foundation

/// Structural validation for one `A2UIServerMessage` against the pinned
/// Basic Catalog matrix and named safety limits, given the surfaces already
/// known in this session. Returns `nil` on success or a typed
/// `A2UIValidationIssue` describing exactly why the item was rejected.
///
/// Validation never mutates state — `A2UISurfaceReducer` calls this before
/// applying an item and only applies items that pass. Known-component
/// property matrices are enforced by typed `A2UIComponent` decoding.
public enum A2UIValidator {
    public static func validate(_ message: A2UIServerMessage,
                                existingSurfaces: [String: A2UISurfaceState]) -> A2UIValidationIssue? {
        switch message {
        case .createSurface(let surfaceID, let catalogID, let theme, _):
            if existingSurfaces[surfaceID] != nil {
                return .init(code: "DUPLICATE_SURFACE", surfaceID: surfaceID,
                             message: "createSurface for an existing live surfaceId '\(surfaceID)'. Delete it first.")
            }
            guard existingSurfaces.count < A2UILimits.maxSurfacesPerSession else {
                return .init(code: "LIMIT_EXCEEDED", surfaceID: surfaceID,
                             message: "Session already has the maximum of \(A2UILimits.maxSurfacesPerSession) live surfaces.")
            }
            if !A2UICatalog.isKnownCatalogID(catalogID) {
                // Unknown catalogs are not a hard validation failure — the
                // renderer degrades to a bounded unsupported card instead.
                return nil
            }
            if theme != nil {
                // Typed theme decode already rejected unknown keys; nothing else to check.
            }
            return nil

        case .updateComponents(let surfaceID, let components):
            guard let surface = existingSurfaces[surfaceID] else {
                return .init(code: "UNKNOWN_SURFACE", surfaceID: surfaceID,
                             message: "updateComponents for a surfaceId with no prior createSurface.")
            }
            guard !components.isEmpty else {
                return .init(code: "VALIDATION_FAILED", surfaceID: surfaceID,
                             message: "updateComponents.components must not be empty.")
            }
            let projectedCount = surface.components.count + components.count
            guard projectedCount <= A2UILimits.maxComponentsPerSurface else {
                return .init(code: "LIMIT_EXCEEDED", surfaceID: surfaceID,
                             message: "Surface would exceed \(A2UILimits.maxComponentsPerSurface) components.")
            }
            let isKnownCatalog = A2UICatalog.isKnownCatalogID(surface.catalogID)
            for component in components {
                if let issue = validateComponent(component,
                                                 surfaceID: surfaceID,
                                                 enforceKnownCatalog: isKnownCatalog) {
                    return issue
                }
            }
            return nil

        case .updateDataModel(let surfaceID, let path, _):
            guard existingSurfaces[surfaceID] != nil else {
                return .init(code: "UNKNOWN_SURFACE", surfaceID: surfaceID,
                             message: "updateDataModel for a surfaceId with no prior createSurface.")
            }
            guard A2UIJSONPointer.tokens(path.rawValue) != nil else {
                return .init(code: "VALIDATION_FAILED", surfaceID: surfaceID, path: path.rawValue,
                             message: "updateDataModel.path is not a valid JSON Pointer.")
            }
            return nil

        case .deleteSurface(let surfaceID):
            guard existingSurfaces[surfaceID] != nil else {
                return .init(code: "UNKNOWN_SURFACE", surfaceID: surfaceID,
                             message: "deleteSurface for a surfaceId with no prior createSurface.")
            }
            return nil
        }
    }

    private static func validateComponent(_ component: A2UIComponent,
                                          surfaceID: String,
                                          enforceKnownCatalog: Bool) -> A2UIValidationIssue? {
        guard !component.id.isEmpty else {
            return .init(code: "VALIDATION_FAILED", surfaceID: surfaceID,
                         message: "Component is missing a non-empty 'id'.")
        }
        guard enforceKnownCatalog else { return nil }
        if case .unknown(let opaque) = component.body {
            return .init(code: "UNKNOWN_COMPONENT", surfaceID: surfaceID, path: "/components/\(component.id)",
                         message: "Unknown Basic Catalog component '\(opaque.kindName)'.")
        }
        if case .button(let props) = component.body {
            if case .functionCall(let call) = props.action {
                guard A2UICatalog.functionNames.contains(call.name) else {
                    return .init(code: "VALIDATION_FAILED", surfaceID: surfaceID,
                                 path: "/components/\(component.id)/action/functionCall",
                                 message: "action.functionCall.call is missing or not in the catalog's function list.")
                }
            }
        }
        if A2UICatalog.isCheckable(component.body) {
            let checks: [A2UICheckRule]?
            switch component.body {
            case .checkBox(let props): checks = props.checks
            case .textField(let props): checks = props.checks
            case .dateTimeInput(let props): checks = props.checks
            case .choicePicker(let props): checks = props.checks
            case .button(let props): checks = props.checks
            case .slider(let props): checks = props.checks
            default: checks = nil
            }
            if let checks {
                for check in checks where check.message.isEmpty {
                    return .init(code: "VALIDATION_FAILED", surfaceID: surfaceID,
                                 path: "/components/\(component.id)/checks",
                                 message: "Each check requires 'condition' and 'message'.")
                }
            }
        }
        return nil
    }
}
