import Foundation

public struct A2UIAccessibilityAttributes: Sendable, Hashable, Codable {
    public var label: A2UIDynamicString?
    public var description: A2UIDynamicString?

    public init(label: A2UIDynamicString? = nil, description: A2UIDynamicString? = nil) {
        self.label = label
        self.description = description
    }

    package init?(json: JSONValue?) throws {
        guard let json, case .object(let object) = json else { return nil }
        label = try object["label"].map { try A2UIDynamicString(json: $0) }
        description = try object["description"].map { try A2UIDynamicString(json: $0) }
    }

    package var jsonValue: JSONValue {
        var object: [String: JSONValue] = [:]
        if let label { object["label"] = label.jsonValue }
        if let description { object["description"] = description.jsonValue }
        return .object(object)
    }
}

public struct A2UICheckRule: Sendable, Hashable, Codable {
    public var condition: A2UIDynamicBoolean
    public var message: String

    public init(condition: A2UIDynamicBoolean, message: String) {
        self.condition = condition
        self.message = message
    }

    package init(json: JSONValue) throws {
        guard case .object(let object) = json,
              let conditionJSON = object["condition"],
              let message = object["message"]?.stringValue else {
            throw DecodingError.dataCorrupted(.init(codingPath: [],
                                                    debugDescription: "Check requires condition and message"))
        }
        condition = try A2UIDynamicBoolean(json: conditionJSON)
        self.message = message
    }

    package var jsonValue: JSONValue {
        .object(["condition": condition.jsonValue, "message": .string(message)])
    }
}

public enum A2UIAction: Sendable, Hashable, Codable {
    case event(name: String, context: [String: A2UIDynamicValue])
    case functionCall(A2UIFunctionCall)

    package init(json: JSONValue) throws {
        guard case .object(let object) = json else {
            throw DecodingError.dataCorrupted(.init(codingPath: [], debugDescription: "action must be an object"))
        }
        if let event = object["event"] {
            guard case .object(let eventObject) = event,
                  let name = eventObject["name"]?.stringValue else {
                throw DecodingError.dataCorrupted(.init(codingPath: [],
                                                        debugDescription: "action.event requires string name"))
            }
            var context: [String: A2UIDynamicValue] = [:]
            if let contextObject = eventObject["context"]?.objectValue {
                for (key, value) in contextObject {
                    context[key] = try A2UIDynamicValue(json: value)
                }
            }
            self = .event(name: name, context: context)
        } else if let call = object["functionCall"] {
            self = .functionCall(try A2UIFunctionCall(json: call))
        } else {
            throw DecodingError.dataCorrupted(.init(codingPath: [],
                                                    debugDescription: "action requires event or functionCall"))
        }
    }

    package var jsonValue: JSONValue {
        switch self {
        case .event(let name, let context):
            var event: [String: JSONValue] = ["name": .string(name)]
            if !context.isEmpty {
                event["context"] = .object(context.mapValues(\.jsonValue))
            }
            return .object(["event": .object(event)])
        case .functionCall(let call):
            return .object(["functionCall": call.jsonValue])
        }
    }
}

public enum A2UIChildList: Sendable, Hashable, Codable {
    case fixed([String])
    case template(componentID: String, path: String)

    package init(json: JSONValue) throws {
        if let array = json.arrayValue {
            let ids = array.compactMap(\.stringValue)
            guard ids.count == array.count else {
                throw DecodingError.dataCorrupted(.init(codingPath: [],
                                                        debugDescription: "ChildList array must be component ids"))
            }
            self = .fixed(ids)
            return
        }
        guard case .object(let object) = json,
              let componentID = object["componentId"]?.stringValue,
              let path = object["path"]?.stringValue else {
            throw DecodingError.dataCorrupted(.init(codingPath: [],
                                                    debugDescription: "ChildList template requires componentId and path"))
        }
        self = .template(componentID: componentID, path: path)
    }

    package var jsonValue: JSONValue {
        switch self {
        case .fixed(let ids): return .array(ids.map(JSONValue.string))
        case .template(let componentID, let path):
            return .object(["componentId": .string(componentID), "path": .string(path)])
        }
    }
}

public enum A2UIMainAxisJustify: String, Sendable, Hashable, Codable {
    case start, center, end, spaceBetween, spaceAround, spaceEvenly, stretch
}

public enum A2UICrossAxisAlign: String, Sendable, Hashable, Codable {
    case start, center, end, stretch
}

public enum A2UITextVariant: String, Sendable, Hashable, Codable {
    case h1, h2, h3, h4, h5, caption, body
}

public enum A2UIImageFit: String, Sendable, Hashable, Codable {
    case contain, cover, fill, none, scaleDown
}

public enum A2UIImageVariant: String, Sendable, Hashable, Codable {
    case icon, avatar, smallFeature, mediumFeature, largeFeature, header
}

public enum A2UIListDirection: String, Sendable, Hashable, Codable {
    case vertical, horizontal
}

public enum A2UIDividerAxis: String, Sendable, Hashable, Codable {
    case horizontal, vertical
}

public enum A2UIButtonVariant: String, Sendable, Hashable, Codable {
    case `default`, primary, borderless
}

public enum A2UITextFieldVariant: String, Sendable, Hashable, Codable {
    case longText, number, shortText, obscured

    package init(wire: String) {
        switch wire {
        case "password", "secure", "obscured": self = .obscured
        case "longText": self = .longText
        case "number": self = .number
        case "shortText": self = .shortText
        default: self = .shortText
        }
    }

    public var isObscured: Bool { self == .obscured }
}

public enum A2UIChoicePickerVariant: String, Sendable, Hashable, Codable {
    case multipleSelection, mutuallyExclusive
}

public enum A2UIChoiceDisplayStyle: String, Sendable, Hashable, Codable {
    case checkbox, chips
}

public enum A2UIIconName: Sendable, Hashable, Codable {
    case catalog(String)
    case svgPath(String)
    case binding(A2UIDataBinding)

    package init(json: JSONValue) throws {
        if let name = json.stringValue {
            self = .catalog(name)
            return
        }
        guard case .object(let object) = json else {
            throw DecodingError.dataCorrupted(.init(codingPath: [], debugDescription: "Invalid Icon.name"))
        }
        if let path = object["path"]?.stringValue, object.keys.allSatisfy({ $0 == "path" }) {
            self = .binding(A2UIDataBinding(path: path))
        } else if let svgPath = object["svgPath"]?.stringValue {
            self = .svgPath(svgPath)
        } else {
            throw DecodingError.dataCorrupted(.init(codingPath: [], debugDescription: "Invalid Icon.name object"))
        }
    }

    package var jsonValue: JSONValue {
        switch self {
        case .catalog(let name): return .string(name)
        case .svgPath(let path): return .object(["svgPath": .string(path)])
        case .binding(let binding): return .object(["path": .string(binding.path)])
        }
    }

    public var catalogSymbol: String? {
        guard case .catalog(let name) = self else { return nil }
        return name
    }
}
