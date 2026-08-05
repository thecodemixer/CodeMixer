import Foundation

/// Named functions from the A2UI Basic Catalog expression language
/// (`{"call": "...", "args": {...}}`). Wire strings decode via `rawValue`;
/// switch on the typed case inside the evaluator and validator.
///
/// `now` is only valid as the `now()` shorthand inside `formatString`
/// interpolation — it is intentionally absent from
/// `A2UICatalog.functions` so `{"call":"now"}` stays rejected.
public enum A2UIFunctionName: String, Sendable, Hashable, Codable, CaseIterable {
    case required
    case regex
    case length
    case numeric
    case email
    case formatString
    case formatNumber
    case formatCurrency
    case formatDate
    case pluralize
    case openUrl
    case and
    case or
    case not
    case now

    /// `true` for functions that must not appear as a `DynamicValue`
    /// (side-effect only — today just `openUrl`).
    public var isVoid: Bool {
        self == .openUrl
    }

    /// Functions accepted as `{"call":...}` in DynamicValue / action
    /// `functionCall` expressions. Excludes `now` (interpolation-only).
    public var isCallExpression: Bool {
        self != .now
    }
}
