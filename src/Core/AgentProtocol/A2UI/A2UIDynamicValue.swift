import Foundation

/// Data-binding path expression (`{"path": "..."}`).
public struct A2UIDataBinding: Sendable, Hashable, Codable {
    public let path: String

    public init(path: String) {
        self.path = path
    }
}

public enum A2UIReturnType: String, Sendable, Hashable, Codable {
    case string, number, boolean, array, object, any, void
}

public enum A2UIFunctionArgument: Sendable, Hashable, Codable {
    case value(A2UIDynamicValue)
    case object([String: A2UIFunctionArgument])

    public init(from decoder: any Decoder) throws {
        let container = try decoder.singleValueContainer()
        let json = try container.decode(JSONValue.self)
        self = try A2UIFunctionArgument(json: json)
    }

    public func encode(to encoder: any Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(jsonValue)
    }

    package init(json: JSONValue) throws {
        if case .object(let object) = json,
           object["path"] != nil || object["call"] != nil
            || object.keys.contains(where: { ["string", "number", "boolean"].contains($0) }) {
            // Prefer DynamicValue shapes; plain config objects fall through.
            if let dynamic = try? A2UIDynamicValue(json: json) {
                self = .value(dynamic)
                return
            }
        }
        if case .object(let object) = json {
            var nested: [String: A2UIFunctionArgument] = [:]
            for (key, value) in object {
                nested[key] = try A2UIFunctionArgument(json: value)
            }
            self = .object(nested)
            return
        }
        self = .value(try A2UIDynamicValue(json: json))
    }

    package var jsonValue: JSONValue {
        switch self {
        case .value(let value): return value.jsonValue
        case .object(let object): return .object(object.mapValues(\.jsonValue))
        }
    }

    public var asDynamicValue: A2UIDynamicValue? {
        guard case .value(let value) = self else { return nil }
        return value
    }

    public var asObject: [String: A2UIFunctionArgument]? {
        guard case .object(let object) = self else { return nil }
        return object
    }
}

public struct A2UIFunctionCall: Sendable, Hashable, Codable {
    public let name: A2UIFunctionName
    public let args: [String: A2UIFunctionArgument]
    public let returnType: A2UIReturnType?

    public init(name: A2UIFunctionName,
                args: [String: A2UIFunctionArgument] = [:],
                returnType: A2UIReturnType? = nil) {
        self.name = name
        self.args = args
        self.returnType = returnType
    }

    package init(json: JSONValue) throws {
        guard case .object(let object) = json,
              let callRaw = object["call"]?.stringValue,
              let name = A2UIFunctionName(rawValue: callRaw) else {
            throw DecodingError.dataCorrupted(.init(codingPath: [],
                                                    debugDescription: "FunctionCall requires string 'call'"))
        }
        self.name = name
        if let returnRaw = object["returnType"]?.stringValue {
            returnType = A2UIReturnType(rawValue: returnRaw)
        } else {
            returnType = nil
        }
        if let argsObject = object["args"]?.objectValue {
            var parsed: [String: A2UIFunctionArgument] = [:]
            for (key, value) in argsObject {
                parsed[key] = try A2UIFunctionArgument(json: value)
            }
            args = parsed
        } else {
            args = [:]
        }
    }

    package var jsonValue: JSONValue {
        var object: [String: JSONValue] = ["call": .string(name.rawValue)]
        if let returnType { object["returnType"] = .string(returnType.rawValue) }
        if !args.isEmpty {
            object["args"] = .object(args.mapValues(\.jsonValue))
        }
        return .object(object)
    }
}

public enum A2UIDynamicValue: Sendable, Hashable, Codable {
    case string(String)
    case number(Double)
    case boolean(Bool)
    case array([A2UIDynamicValue])
    case binding(A2UIDataBinding)
    case call(A2UIFunctionCall)

    public init(from decoder: any Decoder) throws {
        let container = try decoder.singleValueContainer()
        self = try A2UIDynamicValue(json: try container.decode(JSONValue.self))
    }

    public func encode(to encoder: any Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(jsonValue)
    }

    package init(json: JSONValue) throws {
        switch json {
        case .string(let value): self = .string(value)
        case .number(let value): self = .number(value)
        case .bool(let value): self = .boolean(value)
        case .array(let values):
            self = .array(try values.map { try A2UIDynamicValue(json: $0) })
        case .object(let object):
            if let path = object["path"]?.stringValue, object.keys.allSatisfy({ $0 == "path" }) {
                self = .binding(A2UIDataBinding(path: path))
            } else if object["call"] != nil {
                self = .call(try A2UIFunctionCall(json: json))
            } else {
                throw DecodingError.dataCorrupted(.init(codingPath: [],
                                                        debugDescription: "Unsupported DynamicValue object"))
            }
        case .null:
            throw DecodingError.dataCorrupted(.init(codingPath: [],
                                                    debugDescription: "DynamicValue cannot be null"))
        }
    }

    package var jsonValue: JSONValue {
        switch self {
        case .string(let value): return .string(value)
        case .number(let value): return .number(value)
        case .boolean(let value): return .bool(value)
        case .array(let values): return .array(values.map(\.jsonValue))
        case .binding(let binding): return .object(["path": .string(binding.path)])
        case .call(let call): return call.jsonValue
        }
    }
}

public enum A2UIDynamicString: Sendable, Hashable, Codable {
    case literal(String)
    case binding(A2UIDataBinding)
    case call(A2UIFunctionCall)

    public init(from decoder: any Decoder) throws {
        let container = try decoder.singleValueContainer()
        self = try A2UIDynamicString(json: try container.decode(JSONValue.self))
    }

    public func encode(to encoder: any Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(jsonValue)
    }

    package init(json: JSONValue) throws {
        switch json {
        case .string(let value): self = .literal(value)
        case .object(let object) where object["path"] != nil && object.keys.allSatisfy({ $0 == "path" }):
            guard let path = object["path"]?.stringValue else {
                throw DecodingError.dataCorrupted(.init(codingPath: [], debugDescription: "Invalid path binding"))
            }
            self = .binding(A2UIDataBinding(path: path))
        case .object where json.objectValue?["call"] != nil:
            self = .call(try A2UIFunctionCall(json: json))
        default:
            throw DecodingError.dataCorrupted(.init(codingPath: [], debugDescription: "Invalid DynamicString"))
        }
    }

    package var jsonValue: JSONValue {
        switch self {
        case .literal(let value): return .string(value)
        case .binding(let binding): return .object(["path": .string(binding.path)])
        case .call(let call): return call.jsonValue
        }
    }

    public var asDynamicValue: A2UIDynamicValue {
        switch self {
        case .literal(let value): return .string(value)
        case .binding(let binding): return .binding(binding)
        case .call(let call): return .call(call)
        }
    }
}

public enum A2UIDynamicNumber: Sendable, Hashable, Codable {
    case literal(Double)
    case binding(A2UIDataBinding)
    case call(A2UIFunctionCall)

    public init(from decoder: any Decoder) throws {
        let container = try decoder.singleValueContainer()
        self = try A2UIDynamicNumber(json: try container.decode(JSONValue.self))
    }

    public func encode(to encoder: any Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(jsonValue)
    }

    package init(json: JSONValue) throws {
        switch json {
        case .number(let value): self = .literal(value)
        case .object(let object) where object["path"] != nil && object.keys.allSatisfy({ $0 == "path" }):
            guard let path = object["path"]?.stringValue else {
                throw DecodingError.dataCorrupted(.init(codingPath: [], debugDescription: "Invalid path binding"))
            }
            self = .binding(A2UIDataBinding(path: path))
        case .object where json.objectValue?["call"] != nil:
            self = .call(try A2UIFunctionCall(json: json))
        default:
            throw DecodingError.dataCorrupted(.init(codingPath: [], debugDescription: "Invalid DynamicNumber"))
        }
    }

    package var jsonValue: JSONValue {
        switch self {
        case .literal(let value): return .number(value)
        case .binding(let binding): return .object(["path": .string(binding.path)])
        case .call(let call): return call.jsonValue
        }
    }

    public var asDynamicValue: A2UIDynamicValue {
        switch self {
        case .literal(let value): return .number(value)
        case .binding(let binding): return .binding(binding)
        case .call(let call): return .call(call)
        }
    }
}

public enum A2UIDynamicBoolean: Sendable, Hashable, Codable {
    case literal(Bool)
    case binding(A2UIDataBinding)
    case call(A2UIFunctionCall)

    public init(from decoder: any Decoder) throws {
        let container = try decoder.singleValueContainer()
        self = try A2UIDynamicBoolean(json: try container.decode(JSONValue.self))
    }

    public func encode(to encoder: any Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(jsonValue)
    }

    package init(json: JSONValue) throws {
        switch json {
        case .bool(let value): self = .literal(value)
        case .object(let object) where object["path"] != nil && object.keys.allSatisfy({ $0 == "path" }):
            guard let path = object["path"]?.stringValue else {
                throw DecodingError.dataCorrupted(.init(codingPath: [], debugDescription: "Invalid path binding"))
            }
            self = .binding(A2UIDataBinding(path: path))
        case .object where json.objectValue?["call"] != nil:
            self = .call(try A2UIFunctionCall(json: json))
        default:
            throw DecodingError.dataCorrupted(.init(codingPath: [], debugDescription: "Invalid DynamicBoolean"))
        }
    }

    package var jsonValue: JSONValue {
        switch self {
        case .literal(let value): return .bool(value)
        case .binding(let binding): return .object(["path": .string(binding.path)])
        case .call(let call): return call.jsonValue
        }
    }

    public var asDynamicValue: A2UIDynamicValue {
        switch self {
        case .literal(let value): return .boolean(value)
        case .binding(let binding): return .binding(binding)
        case .call(let call): return .call(call)
        }
    }
}

public enum A2UIDynamicStringList: Sendable, Hashable, Codable {
    case literal([String])
    case binding(A2UIDataBinding)
    case call(A2UIFunctionCall)

    public init(from decoder: any Decoder) throws {
        let container = try decoder.singleValueContainer()
        self = try A2UIDynamicStringList(json: try container.decode(JSONValue.self))
    }

    public func encode(to encoder: any Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(jsonValue)
    }

    package init(json: JSONValue) throws {
        switch json {
        case .array(let values):
            let strings = values.compactMap(\.stringValue)
            guard strings.count == values.count else {
                throw DecodingError.dataCorrupted(.init(codingPath: [], debugDescription: "DynamicStringList literals must be strings"))
            }
            self = .literal(strings)
        case .object(let object) where object["path"] != nil && object.keys.allSatisfy({ $0 == "path" }):
            guard let path = object["path"]?.stringValue else {
                throw DecodingError.dataCorrupted(.init(codingPath: [], debugDescription: "Invalid path binding"))
            }
            self = .binding(A2UIDataBinding(path: path))
        case .object where json.objectValue?["call"] != nil:
            self = .call(try A2UIFunctionCall(json: json))
        default:
            throw DecodingError.dataCorrupted(.init(codingPath: [], debugDescription: "Invalid DynamicStringList"))
        }
    }

    package var jsonValue: JSONValue {
        switch self {
        case .literal(let values): return .array(values.map(JSONValue.string))
        case .binding(let binding): return .object(["path": .string(binding.path)])
        case .call(let call): return call.jsonValue
        }
    }

    public var asDynamicValue: A2UIDynamicValue {
        switch self {
        case .literal(let values): return .array(values.map(A2UIDynamicValue.string))
        case .binding(let binding): return .binding(binding)
        case .call(let call): return .call(call)
        }
    }
}
