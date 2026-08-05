import AgentProtocol
import Foundation

/// Evaluates A2UI dynamic expressions against a data document, an optional
/// bounded client-local overlay, and repeated-list scope paths.
///
/// Used both by the SwiftUI renderer (read path) and by the engine when it
/// re-resolves a validated `A2UIInteractionIntent` into a concrete
/// `A2UIActionEnvelope`.
public struct A2UIEvaluator: Sendable {
    public enum EvaluationError: Error, Sendable, Equatable {
        case depthExceeded
        case callCountExceeded
        case unknownFunction(String)
        case voidFunctionUsedAsValue(A2UIFunctionName)
        case malformedExpression
        case resolvedStringTooLong
    }

    private let dataModel: A2UIDataDocument
    private let overlay: A2UILocalOverlay
    private let scopePaths: [String]
    private let locale: Locale
    private let timeZone: TimeZone
    private let now: Date?
    private var callBudget: Int

    public init(dataModel: A2UIDataDocument,
                overlay: A2UILocalOverlay = .empty,
                scopePaths: [String] = [],
                locale: Locale = Locale(identifier: "en_US"),
                timeZone: TimeZone = TimeZone(identifier: "UTC") ?? .current,
                now: Date? = nil) {
        self.dataModel = dataModel
        self.overlay = overlay
        self.scopePaths = scopePaths
        self.locale = locale
        self.timeZone = timeZone
        self.now = now
        callBudget = A2UILimits.maxExpressionCallCount
    }

    public mutating func resolve(_ value: A2UIDynamicValue, depth: Int = 0) throws -> A2UIResolvedValue {
        guard depth < A2UILimits.maxExpressionDepth else { throw EvaluationError.depthExceeded }
        switch value {
        case .string(let string): return .string(string)
        case .number(let number): return .number(number)
        case .boolean(let bool): return .bool(bool)
        case .array(let values):
            return .array(try values.map { try resolve($0, depth: depth + 1) })
        case .binding(let binding):
            return lookup(path: binding.path)
        case .call(let call):
            guard callBudget > 0 else { throw EvaluationError.callCountExceeded }
            callBudget -= 1
            guard A2UICatalog.functionNames.contains(call.name) else {
                throw EvaluationError.unknownFunction(call.name.rawValue)
            }
            guard !A2UICatalog.voidFunctions.contains(call.name) else {
                throw EvaluationError.voidFunctionUsedAsValue(call.name)
            }
            return try invoke(call, depth: depth + 1)
        }
    }

    public mutating func resolve(_ value: A2UIDynamicString, depth: Int = 0) throws -> String {
        try resolveString(value.asDynamicValue, depth: depth)
    }

    public mutating func resolve(_ value: A2UIDynamicBoolean, depth: Int = 0) throws -> Bool {
        try resolveBool(value.asDynamicValue, depth: depth)
    }

    public mutating func resolve(_ value: A2UIDynamicNumber, depth: Int = 0) throws -> Double {
        try resolveNumber(value.asDynamicValue, depth: depth)
    }

    public mutating func resolveString(_ value: A2UIDynamicValue, depth: Int = 0) throws -> String {
        let resolved = try resolve(value, depth: depth)
        let text = resolved.stringValue ?? A2UIEvaluator.plainDescription(resolved)
        guard text.count <= A2UILimits.maxResolvedStringLength else { throw EvaluationError.resolvedStringTooLong }
        return text
    }

    public mutating func resolveBool(_ value: A2UIDynamicValue, depth: Int = 0) throws -> Bool {
        try resolve(value, depth: depth).boolValue ?? false
    }

    public mutating func resolveNumber(_ value: A2UIDynamicValue, depth: Int = 0) throws -> Double {
        try resolve(value, depth: depth).numberValue ?? .nan
    }

    public mutating func resolveContext(_ context: [String: A2UIDynamicValue]) throws -> [String: A2UIResolvedValue] {
        var resolved: [String: A2UIResolvedValue] = [:]
        for (key, value) in context {
            resolved[key] = try resolve(value)
        }
        return resolved
    }

    private func lookup(path: String) -> A2UIResolvedValue {
        let resolvedPath = A2UIJSONPointer.resolveScoped(path, scopePaths: scopePaths)
        if let overlayValue = overlay[A2UIJSONPointerPath(resolvedPath)] { return overlayValue }
        return A2UIJSONPointer.value(at: resolvedPath, in: dataModel) ?? .null
    }

    private mutating func invoke(_ call: A2UIFunctionCall, depth: Int) throws -> A2UIResolvedValue {
        let args = call.args
        switch call.name {
        case .required:
            let value = try resolveArg(args["value"], depth: depth)
            return .bool(!A2UIEvaluator.isEmpty(value))
        case .regex:
            let value = try resolveStringArg(args["value"], depth: depth)
            guard case .value(.string(let pattern)) = args["pattern"] ?? .value(.string("")),
                  pattern.count <= A2UILimits.maxRegexPatternLength,
                  value.count <= A2UILimits.maxRegexInputLength,
                  let regex = try? NSRegularExpression(pattern: pattern) else { return .bool(false) }
            let range = NSRange(value.startIndex..., in: value)
            return .bool(regex.firstMatch(in: value, range: range) != nil)
        case .length:
            let value = try resolveStringArg(args["value"], depth: depth)
            let min = literalNumber(args["min"])
            let max = literalNumber(args["max"])
            let count = Double(value.count)
            if let min, count < min { return .bool(false) }
            if let max, count > max { return .bool(false) }
            return .bool(true)
        case .numeric:
            let value = try resolveNumberArg(args["value"], depth: depth)
            let min = literalNumber(args["min"])
            let max = literalNumber(args["max"])
            if let min, value < min { return .bool(false) }
            if let max, value > max { return .bool(false) }
            return .bool(!value.isNaN)
        case .email:
            let value = try resolveStringArg(args["value"], depth: depth)
            return .bool(A2UIEvaluator.looksLikeEmail(value))
        case .formatString:
            let template = try resolveStringArg(args["value"], depth: depth)
            return .string(try interpolate(template, depth: depth))
        case .formatNumber:
            let value = try resolveNumberArg(args["value"], depth: depth)
            let decimals = try args["decimals"].map { try resolveNumberArg($0, depth: depth) }
            let grouping = try args["grouping"].map { try resolveBoolArg($0, depth: depth) } ?? true
            return .string(A2UIEvaluator.formatNumber(value, decimals: decimals, grouping: grouping, locale: locale))
        case .formatCurrency:
            let value = try resolveNumberArg(args["value"], depth: depth)
            let currency = try resolveStringArg(args["currency"] ?? .value(.string("USD")), depth: depth)
            let decimals = try args["decimals"].map { try resolveNumberArg($0, depth: depth) }
            return .string(A2UIEvaluator.formatCurrency(value, currency: currency, decimals: decimals, locale: locale))
        case .formatDate:
            let raw = try resolveArg(args["value"], depth: depth)
            let format = try resolveStringArg(args["format"] ?? .value(.string("")), depth: depth)
            guard format.count <= A2UILimits.maxFormatPatternLength else { return .string("") }
            return .string(A2UIEvaluator.formatDate(raw, pattern: format, locale: locale, timeZone: timeZone))
        case .pluralize:
            let count = try resolveNumberArg(args["value"], depth: depth)
            return .string(try pluralize(count: count, args: args, depth: depth))
        case .and:
            var result = true
            for value in arrayArgs(args["values"]) where result {
                result = try resolveBoolArg(value, depth: depth)
            }
            return .bool(result)
        case .or:
            var result = false
            for value in arrayArgs(args["values"]) where !result {
                result = try resolveBoolArg(value, depth: depth)
            }
            return .bool(result)
        case .not:
            return .bool(!(try resolveBoolArg(args["value"] ?? .value(.boolean(false)), depth: depth)))
        case .openUrl, .now:
            throw EvaluationError.unknownFunction(call.name.rawValue)
        }
    }

    private mutating func resolveArg(_ arg: A2UIFunctionArgument?, depth: Int) throws -> A2UIResolvedValue {
        guard let arg, let value = arg.asDynamicValue else { return .null }
        return try resolve(value, depth: depth)
    }

    private mutating func resolveStringArg(_ arg: A2UIFunctionArgument?, depth: Int) throws -> String {
        try resolveString(arg?.asDynamicValue ?? .string(""), depth: depth)
    }

    private mutating func resolveNumberArg(_ arg: A2UIFunctionArgument?, depth: Int) throws -> Double {
        try resolveNumber(arg?.asDynamicValue ?? .number(.nan), depth: depth)
    }

    private mutating func resolveBoolArg(_ arg: A2UIFunctionArgument?, depth: Int) throws -> Bool {
        try resolveBool(arg?.asDynamicValue ?? .boolean(false), depth: depth)
    }

    private func literalNumber(_ arg: A2UIFunctionArgument?) -> Double? {
        guard case .value(.number(let number)) = arg else { return nil }
        return number
    }

    private func arrayArgs(_ arg: A2UIFunctionArgument?) -> [A2UIFunctionArgument] {
        guard case .value(.array(let values)) = arg else { return [] }
        return values.map { .value($0) }
    }

    private mutating func interpolate(_ template: String, depth: Int) throws -> String {
        var result = ""
        var index = template.startIndex
        while index < template.endIndex {
            if template[index] == "\\",
               template.index(after: index) < template.endIndex,
               template[template.index(after: index)...].hasPrefix("${") {
                result.append("${")
                index = template.index(index, offsetBy: 3)
                continue
            }
            if template[index...].hasPrefix("${"),
               let close = template[index...].firstIndex(of: "}") {
                let exprStart = template.index(index, offsetBy: 2)
                let expression = String(template[exprStart..<close])
                result += try resolveInlineExpression(expression, depth: depth)
                index = template.index(after: close)
                continue
            }
            result.append(template[index])
            index = template.index(after: index)
        }
        return result
    }

    private mutating func resolveInlineExpression(_ expression: String, depth: Int) throws -> String {
        let trimmed = expression.trimmingCharacters(in: .whitespaces)
        if trimmed.hasSuffix("()") {
            let name = String(trimmed.dropLast(2))
            if A2UIFunctionName(rawValue: name) == .now { return isoNow() }
            return ""
        }
        return try resolveString(.binding(A2UIDataBinding(path: trimmed)), depth: depth)
    }

    private mutating func pluralize(count: Double,
                                    args: [String: A2UIFunctionArgument],
                                    depth: Int) throws -> String {
        let category = A2UIEvaluator.cldrCategory(for: count, locale: locale)
        if let value = args[category] {
            return try resolveStringArg(value, depth: depth)
        }
        return try resolveStringArg(args["other"] ?? .value(.string("")), depth: depth)
    }

    private static func isEmpty(_ value: A2UIResolvedValue) -> Bool {
        switch value {
        case .null: return true
        case .string(let s): return s.isEmpty
        case .array(let a): return a.isEmpty
        case .object(let o): return o.isEmpty
        case .bool, .number: return false
        }
    }

    private static func looksLikeEmail(_ value: String) -> Bool {
        guard value.count <= A2UILimits.maxRegexInputLength else { return false }
        guard let atIndex = value.firstIndex(of: "@"), atIndex != value.startIndex else { return false }
        let domain = value[value.index(after: atIndex)...]
        return domain.contains(".") && !domain.hasPrefix(".") && !domain.hasSuffix(".") && !value.contains(" ")
    }

    private static func formatNumber(_ value: Double, decimals: Double?, grouping: Bool, locale: Locale) -> String {
        let formatter = NumberFormatter()
        formatter.locale = locale
        formatter.numberStyle = .decimal
        formatter.usesGroupingSeparator = grouping
        if let decimals {
            formatter.minimumFractionDigits = Int(decimals)
            formatter.maximumFractionDigits = Int(decimals)
        }
        return formatter.string(from: NSNumber(value: value)) ?? String(value)
    }

    private static func formatCurrency(_ value: Double, currency: String, decimals: Double?, locale: Locale) -> String {
        let formatter = NumberFormatter()
        formatter.locale = locale
        formatter.numberStyle = .currency
        formatter.currencyCode = currency
        if let decimals {
            formatter.minimumFractionDigits = Int(decimals)
            formatter.maximumFractionDigits = Int(decimals)
        }
        return formatter.string(from: NSNumber(value: value)) ?? "\(currency) \(value)"
    }

    private static func formatDate(_ raw: A2UIResolvedValue, pattern: String, locale: Locale, timeZone: TimeZone) -> String {
        let date: Date
        if let iso = raw.stringValue, let parsed = ISO8601DateFormatter().date(from: iso) {
            date = parsed
        } else if let epoch = raw.numberValue {
            date = Date(timeIntervalSince1970: epoch)
        } else {
            return ""
        }
        let formatter = DateFormatter()
        formatter.locale = locale
        formatter.timeZone = timeZone
        formatter.dateFormat = pattern
        return formatter.string(from: date)
    }

    private func isoNow() -> String {
        guard let now else { return "" }
        return ISO8601DateFormatter().string(from: now)
    }

    private static func cldrCategory(for count: Double, locale: Locale) -> String {
        if count == 0 { return "zero" }
        if count == 1 { return "one" }
        return "other"
    }

    private static func plainDescription(_ value: A2UIResolvedValue) -> String {
        switch value {
        case .null: return ""
        case .bool(let b): return b ? "true" : "false"
        case .number(let n): return n.truncatingRemainder(dividingBy: 1) == 0 ? String(Int(n)) : String(n)
        case .string(let s): return s
        case .array, .object: return ""
        }
    }
}
