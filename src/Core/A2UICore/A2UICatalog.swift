import AgentProtocol
import Foundation

/// Semantic companion for the A2UI v0.9.1 Basic Catalog. Structural required
/// / known property matrices live in typed `A2UIComponent` decoding; this
/// catalog owns cross-cutting sets (checkable, two-way-bound, functions).
public enum A2UICatalog {
    public static let functionNames: Set<A2UIFunctionName> = Set(
        A2UIFunctionName.allCases.filter(\.isCallExpression)
    )

    public static let voidFunctions: Set<A2UIFunctionName> = Set(
        A2UIFunctionName.allCases.filter(\.isVoid)
    )

    public static let checkableBodyMarkers: Set<String> = [
        "checkBox", "textField", "dateTimeInput", "choicePicker", "button", "slider",
    ]

    public static func isKnownCatalogID(_ catalogID: String) -> Bool {
        catalogID == A2UISchemaProfile.basicCatalogID
            || catalogID == A2UISchemaProfile.testScopedCatalogID
    }

    public static func isCheckable(_ body: A2UIComponentBody) -> Bool {
        switch body {
        case .checkBox, .textField, .dateTimeInput, .choicePicker, .button, .slider:
            return true
        default:
            return false
        }
    }

    public static func isTwoWayBound(_ body: A2UIComponentBody) -> Bool {
        switch body {
        case .checkBox, .textField, .dateTimeInput, .choicePicker, .slider:
            return true
        default:
            return false
        }
    }

    public static func isKnownComponentBody(_ body: A2UIComponentBody) -> Bool {
        !body.isUnknown
    }
}
