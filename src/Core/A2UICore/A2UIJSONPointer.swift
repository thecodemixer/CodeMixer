import AgentProtocol
import Foundation

/// RFC 6901 JSON Pointer navigation over `A2UIDataDocument` /
/// `A2UIResolvedValue`. Distinguishes "omitted" (`nil`) from explicit JSON
/// `null` (`.null`) everywhere a caller needs that distinction.
public enum A2UIJSONPointer {
    /// Splits `"/a/b~1c~0d"` into unescaped tokens `["a", "b/c~d"]`. The root
    /// pointer (`""` or `"/"`) yields an empty token list.
    public static func tokens(_ pointer: String) -> [String]? {
        guard pointer.count <= A2UILimits.maxPointerLength else { return nil }
        if pointer.isEmpty || pointer == "/" { return [] }
        guard pointer.hasPrefix("/") else { return nil }
        return pointer.dropFirst().split(separator: "/", omittingEmptySubsequences: false).map { part in
            String(part).replacingOccurrences(of: "~1", with: "/").replacingOccurrences(of: "~0", with: "~")
        }
    }

    public static func value(at pointer: String, in document: A2UIDataDocument) -> A2UIResolvedValue? {
        value(at: pointer, in: A2UIResolvedValue(json: document.json))
    }

    public static func value(at pointer: String, in root: A2UIResolvedValue) -> A2UIResolvedValue? {
        guard let tokens = tokens(pointer) else { return nil }
        return value(at: tokens, in: root)
    }

    private static func value(at tokens: [String], in value: A2UIResolvedValue) -> A2UIResolvedValue? {
        guard let first = tokens.first else { return value }
        let rest = Array(tokens.dropFirst())
        switch value {
        case .object(let object):
            guard let next = object[first] else { return nil }
            return self.value(at: rest, in: next)
        case .array(let array):
            guard let index = Int(first), array.indices.contains(index) else { return nil }
            return self.value(at: rest, in: array[index])
        default:
            return nil
        }
    }

    /// Sets `value` at `pointer`, creating intermediate objects as needed.
    /// Passing `value == nil` removes the key (array removal preserves
    /// indexes as `.null`).
    public static func setting(at pointer: String,
                               to value: A2UIResolvedValue?,
                               in document: A2UIDataDocument) -> A2UIDataDocument {
        let updated = setting(at: pointer, to: value, in: A2UIResolvedValue(json: document.json))
        return A2UIDataDocument(json: updated.jsonValue)
    }

    public static func setting(at pointer: String,
                               to value: A2UIResolvedValue?,
                               in root: A2UIResolvedValue) -> A2UIResolvedValue {
        guard let tokens = tokens(pointer) else { return root }
        guard !tokens.isEmpty else { return value ?? .null }
        return set(tokens, to: value, in: root)
    }

    private static func set(_ tokens: [String],
                            to value: A2UIResolvedValue?,
                            in current: A2UIResolvedValue) -> A2UIResolvedValue {
        guard let first = tokens.first else { return value ?? .null }
        let rest = Array(tokens.dropFirst())
        if rest.isEmpty {
            switch current {
            case .object(var object):
                if let value {
                    object[first] = value
                } else {
                    object.removeValue(forKey: first)
                }
                return .object(object)
            case .array(var array):
                guard let index = Int(first) else { return current }
                while array.count <= index { array.append(.null) }
                if let value {
                    array[index] = value
                } else {
                    array[index] = .null
                }
                return .array(array)
            default:
                var object: [String: A2UIResolvedValue] = [:]
                if let value { object[first] = value }
                return .object(object)
            }
        }
        switch current {
        case .object(var object):
            let child = object[first] ?? .object([:])
            object[first] = set(rest, to: value, in: child)
            return .object(object)
        case .array(var array):
            guard let index = Int(first) else { return current }
            while array.count <= index { array.append(.object([:])) }
            array[index] = set(rest, to: value, in: array[index])
            return .array(array)
        default:
            var object: [String: A2UIResolvedValue] = [:]
            object[first] = set(rest, to: value, in: .object([:]))
            return .object(object)
        }
    }

    /// Resolves a pointer that may be relative to one or more repeated-list
    /// scope base paths (outermost first). Absolute pointers (leading `/`)
    /// are returned unchanged; relative pointers are resolved against the
    /// innermost scope.
    public static func resolveScoped(_ pointer: String, scopePaths: [String]) -> String {
        guard !pointer.hasPrefix("/") else { return pointer }
        guard let innerScope = scopePaths.last else { return "/\(pointer)" }
        let base = innerScope.hasSuffix("/") ? String(innerScope.dropLast()) : innerScope
        return "\(base)/\(pointer)"
    }
}
