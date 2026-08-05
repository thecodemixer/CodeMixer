import Foundation

// MARK: - Component props

public struct A2UITextProps: Sendable, Hashable, Codable {
    public var text: A2UIDynamicString
    public var variant: A2UITextVariant?

    public init(text: A2UIDynamicString, variant: A2UITextVariant? = nil) {
        self.text = text
        self.variant = variant
    }

    package var propsJSON: [String: JSONValue] {
        var object: [String: JSONValue] = ["text": text.jsonValue]
        if let variant { object["variant"] = .string(variant.rawValue) }
        return object
    }
}

public struct A2UIImageProps: Sendable, Hashable, Codable {
    public var url: A2UIDynamicString
    public var description: A2UIDynamicString?
    public var fit: A2UIImageFit?
    public var variant: A2UIImageVariant?

    public init(url: A2UIDynamicString,
                description: A2UIDynamicString? = nil,
                fit: A2UIImageFit? = nil,
                variant: A2UIImageVariant? = nil) {
        self.url = url
        self.description = description
        self.fit = fit
        self.variant = variant
    }

    package var propsJSON: [String: JSONValue] {
        var object: [String: JSONValue] = ["url": url.jsonValue]
        if let description { object["description"] = description.jsonValue }
        if let fit { object["fit"] = .string(fit.rawValue) }
        if let variant { object["variant"] = .string(variant.rawValue) }
        return object
    }
}

public struct A2UIIconProps: Sendable, Hashable, Codable {
    public var name: A2UIIconName

    public init(name: A2UIIconName) {
        self.name = name
    }

    package var propsJSON: [String: JSONValue] {
        ["name": name.jsonValue]
    }
}

public struct A2UIVideoProps: Sendable, Hashable, Codable {
    public var url: A2UIDynamicString

    public init(url: A2UIDynamicString) {
        self.url = url
    }

    package var propsJSON: [String: JSONValue] {
        ["url": url.jsonValue]
    }
}

public struct A2UIAudioPlayerProps: Sendable, Hashable, Codable {
    public var url: A2UIDynamicString
    public var description: A2UIDynamicString?

    public init(url: A2UIDynamicString, description: A2UIDynamicString? = nil) {
        self.url = url
        self.description = description
    }

    package var propsJSON: [String: JSONValue] {
        var object: [String: JSONValue] = ["url": url.jsonValue]
        if let description { object["description"] = description.jsonValue }
        return object
    }
}

public struct A2UIStackProps: Sendable, Hashable, Codable {
    public var children: A2UIChildList
    public var justify: A2UIMainAxisJustify?
    public var align: A2UICrossAxisAlign?

    public init(children: A2UIChildList,
                justify: A2UIMainAxisJustify? = nil,
                align: A2UICrossAxisAlign? = nil) {
        self.children = children
        self.justify = justify
        self.align = align
    }

    package var propsJSON: [String: JSONValue] {
        var object: [String: JSONValue] = ["children": children.jsonValue]
        if let justify { object["justify"] = .string(justify.rawValue) }
        if let align { object["align"] = .string(align.rawValue) }
        return object
    }
}

public struct A2UIListProps: Sendable, Hashable, Codable {
    public var children: A2UIChildList
    public var direction: A2UIListDirection?
    public var align: A2UICrossAxisAlign?

    public init(children: A2UIChildList,
                direction: A2UIListDirection? = nil,
                align: A2UICrossAxisAlign? = nil) {
        self.children = children
        self.direction = direction
        self.align = align
    }

    package var propsJSON: [String: JSONValue] {
        var object: [String: JSONValue] = ["children": children.jsonValue]
        if let direction { object["direction"] = .string(direction.rawValue) }
        if let align { object["align"] = .string(align.rawValue) }
        return object
    }
}

public struct A2UICardProps: Sendable, Hashable, Codable {
    public var child: String

    public init(child: String) {
        self.child = child
    }

    package var propsJSON: [String: JSONValue] {
        ["child": .string(child)]
    }
}

public struct A2UITabItem: Sendable, Hashable, Codable {
    public var title: A2UIDynamicString
    public var child: String

    public init(title: A2UIDynamicString, child: String) {
        self.title = title
        self.child = child
    }

    package var propsJSON: [String: JSONValue] {
        ["title": title.jsonValue, "child": .string(child)]
    }
}

public struct A2UITabsProps: Sendable, Hashable, Codable {
    public var tabs: [A2UITabItem]

    public init(tabs: [A2UITabItem]) {
        self.tabs = tabs
    }

    package var propsJSON: [String: JSONValue] {
        ["tabs": .array(tabs.map { .object($0.propsJSON) })]
    }
}

public struct A2UIModalProps: Sendable, Hashable, Codable {
    public var trigger: String
    public var content: String

    public init(trigger: String, content: String) {
        self.trigger = trigger
        self.content = content
    }

    package var propsJSON: [String: JSONValue] {
        ["trigger": .string(trigger), "content": .string(content)]
    }
}

public struct A2UIDividerProps: Sendable, Hashable, Codable {
    public var axis: A2UIDividerAxis?

    public init(axis: A2UIDividerAxis? = nil) {
        self.axis = axis
    }

    package var propsJSON: [String: JSONValue] {
        var object: [String: JSONValue] = [:]
        if let axis { object["axis"] = .string(axis.rawValue) }
        return object
    }
}

public struct A2UIButtonProps: Sendable, Hashable, Codable {
    public var child: String
    public var action: A2UIAction
    public var variant: A2UIButtonVariant?
    public var checks: [A2UICheckRule]?

    public init(child: String,
                action: A2UIAction,
                variant: A2UIButtonVariant? = nil,
                checks: [A2UICheckRule]? = nil) {
        self.child = child
        self.action = action
        self.variant = variant
        self.checks = checks
    }

    package var propsJSON: [String: JSONValue] {
        var object: [String: JSONValue] = ["child": .string(child), "action": action.jsonValue]
        if let variant { object["variant"] = .string(variant.rawValue) }
        if let checks { object["checks"] = .array(checks.map(\.jsonValue)) }
        return object
    }
}

public struct A2UICheckBoxProps: Sendable, Hashable, Codable {
    public var label: A2UIDynamicString
    public var value: A2UIDynamicBoolean
    public var checks: [A2UICheckRule]?

    public init(label: A2UIDynamicString, value: A2UIDynamicBoolean, checks: [A2UICheckRule]? = nil) {
        self.label = label
        self.value = value
        self.checks = checks
    }

    package var propsJSON: [String: JSONValue] {
        var object: [String: JSONValue] = ["label": label.jsonValue, "value": value.jsonValue]
        if let checks { object["checks"] = .array(checks.map(\.jsonValue)) }
        return object
    }
}

public struct A2UITextFieldProps: Sendable, Hashable, Codable {
    public var label: A2UIDynamicString
    public var value: A2UIDynamicString?
    public var variant: A2UITextFieldVariant?
    public var validationRegexp: String?
    public var checks: [A2UICheckRule]?

    public init(label: A2UIDynamicString,
                value: A2UIDynamicString? = nil,
                variant: A2UITextFieldVariant? = nil,
                validationRegexp: String? = nil,
                checks: [A2UICheckRule]? = nil) {
        self.label = label
        self.value = value
        self.variant = variant
        self.validationRegexp = validationRegexp
        self.checks = checks
    }

    package var propsJSON: [String: JSONValue] {
        var object: [String: JSONValue] = ["label": label.jsonValue]
        if let value { object["value"] = value.jsonValue }
        if let variant { object["variant"] = .string(variant.rawValue) }
        if let validationRegexp { object["validationRegexp"] = .string(validationRegexp) }
        if let checks { object["checks"] = .array(checks.map(\.jsonValue)) }
        return object
    }
}

public struct A2UIDateTimeInputProps: Sendable, Hashable, Codable {
    public var value: A2UIDynamicString
    public var enableDate: Bool?
    public var enableTime: Bool?
    public var min: A2UIDynamicString?
    public var max: A2UIDynamicString?
    public var label: A2UIDynamicString?
    public var checks: [A2UICheckRule]?

    public init(value: A2UIDynamicString,
                enableDate: Bool? = nil,
                enableTime: Bool? = nil,
                min: A2UIDynamicString? = nil,
                max: A2UIDynamicString? = nil,
                label: A2UIDynamicString? = nil,
                checks: [A2UICheckRule]? = nil) {
        self.value = value
        self.enableDate = enableDate
        self.enableTime = enableTime
        self.min = min
        self.max = max
        self.label = label
        self.checks = checks
    }

    package var propsJSON: [String: JSONValue] {
        var object: [String: JSONValue] = ["value": value.jsonValue]
        if let enableDate { object["enableDate"] = .bool(enableDate) }
        if let enableTime { object["enableTime"] = .bool(enableTime) }
        if let min { object["min"] = min.jsonValue }
        if let max { object["max"] = max.jsonValue }
        if let label { object["label"] = label.jsonValue }
        if let checks { object["checks"] = .array(checks.map(\.jsonValue)) }
        return object
    }
}

public struct A2UIChoiceOption: Sendable, Hashable, Codable {
    public var label: A2UIDynamicString
    public var value: String

    public init(label: A2UIDynamicString, value: String) {
        self.label = label
        self.value = value
    }

    package var propsJSON: [String: JSONValue] {
        ["label": label.jsonValue, "value": .string(value)]
    }
}

public struct A2UIChoicePickerProps: Sendable, Hashable, Codable {
    public var options: [A2UIChoiceOption]
    public var value: A2UIDynamicStringList
    public var label: A2UIDynamicString?
    public var variant: A2UIChoicePickerVariant?
    public var displayStyle: A2UIChoiceDisplayStyle?
    public var filterable: Bool?
    public var checks: [A2UICheckRule]?

    public init(options: [A2UIChoiceOption],
                value: A2UIDynamicStringList,
                label: A2UIDynamicString? = nil,
                variant: A2UIChoicePickerVariant? = nil,
                displayStyle: A2UIChoiceDisplayStyle? = nil,
                filterable: Bool? = nil,
                checks: [A2UICheckRule]? = nil) {
        self.options = options
        self.value = value
        self.label = label
        self.variant = variant
        self.displayStyle = displayStyle
        self.filterable = filterable
        self.checks = checks
    }

    package var propsJSON: [String: JSONValue] {
        var object: [String: JSONValue] = [
            "options": .array(options.map { .object($0.propsJSON) }),
            "value": value.jsonValue,
        ]
        if let label { object["label"] = label.jsonValue }
        if let variant { object["variant"] = .string(variant.rawValue) }
        if let displayStyle { object["displayStyle"] = .string(displayStyle.rawValue) }
        if let filterable { object["filterable"] = .bool(filterable) }
        if let checks { object["checks"] = .array(checks.map(\.jsonValue)) }
        return object
    }
}

public struct A2UISliderProps: Sendable, Hashable, Codable {
    public var value: A2UIDynamicNumber
    public var max: Double
    public var min: Double?
    public var label: A2UIDynamicString?
    public var checks: [A2UICheckRule]?

    public init(value: A2UIDynamicNumber,
                max: Double,
                min: Double? = nil,
                label: A2UIDynamicString? = nil,
                checks: [A2UICheckRule]? = nil) {
        self.value = value
        self.max = max
        self.min = min
        self.label = label
        self.checks = checks
    }

    package var propsJSON: [String: JSONValue] {
        var object: [String: JSONValue] = ["value": value.jsonValue, "max": .number(max)]
        if let min { object["min"] = .number(min) }
        if let label { object["label"] = label.jsonValue }
        if let checks { object["checks"] = .array(checks.map(\.jsonValue)) }
        return object
    }
}

// MARK: - Body + component

/// Discriminant + payload for one Basic Catalog component. Unknown catalogs
/// land in `.unknown` with an opaque raw object for lossless replay.
public enum A2UIComponentBody: Sendable, Hashable {
    case text(A2UITextProps)
    case image(A2UIImageProps)
    case icon(A2UIIconProps)
    case video(A2UIVideoProps)
    case audioPlayer(A2UIAudioPlayerProps)
    case row(A2UIStackProps)
    case column(A2UIStackProps)
    case list(A2UIListProps)
    case card(A2UICardProps)
    case tabs(A2UITabsProps)
    case modal(A2UIModalProps)
    case divider(A2UIDividerProps)
    case button(A2UIButtonProps)
    case checkBox(A2UICheckBoxProps)
    case textField(A2UITextFieldProps)
    case dateTimeInput(A2UIDateTimeInputProps)
    case choicePicker(A2UIChoicePickerProps)
    case slider(A2UISliderProps)
    case unknown(A2UIOpaqueComponent)

    /// Wire discriminant for a known Basic Catalog body. Nested here so the
    /// kind vocabulary and the payload cases stay one type — there is no
    /// parallel top-level kind enum and no `Set<String>` of magic names.
    public enum Kind: String, Sendable, Hashable, CaseIterable {
        case text = "Text"
        case image = "Image"
        case icon = "Icon"
        case video = "Video"
        case audioPlayer = "AudioPlayer"
        case row = "Row"
        case column = "Column"
        case list = "List"
        case card = "Card"
        case tabs = "Tabs"
        case modal = "Modal"
        case divider = "Divider"
        case button = "Button"
        case checkBox = "CheckBox"
        case textField = "TextField"
        case dateTimeInput = "DateTimeInput"
        case choicePicker = "ChoicePicker"
        case slider = "Slider"
    }

    /// Known-catalog kind for this body, or `nil` when the body is opaque.
    public var kind: Kind? {
        switch self {
        case .text: return .text
        case .image: return .image
        case .icon: return .icon
        case .video: return .video
        case .audioPlayer: return .audioPlayer
        case .row: return .row
        case .column: return .column
        case .list: return .list
        case .card: return .card
        case .tabs: return .tabs
        case .modal: return .modal
        case .divider: return .divider
        case .button: return .button
        case .checkBox: return .checkBox
        case .textField: return .textField
        case .dateTimeInput: return .dateTimeInput
        case .choicePicker: return .choicePicker
        case .slider: return .slider
        case .unknown: return nil
        }
    }

    /// Wire `component` string. Known bodies use `Kind.rawValue`; opaque
    /// bodies replay the original kind name verbatim.
    public var wireKindName: String {
        if let kind { return kind.rawValue }
        guard case .unknown(let opaque) = self else {
            preconditionFailure("non-unknown body must have a Kind")
        }
        return opaque.kindName
    }

    public var isUnknown: Bool {
        if case .unknown = self { return true }
        return false
    }

    /// Per-kind property bag for the wire object (everything except
    /// `id` / `component` / `weight` / `accessibility`). Opaque bodies
    /// contribute nothing — the whole object is replayed from `raw`.
    package var propsJSON: [String: JSONValue] {
        switch self {
        case .text(let props): return props.propsJSON
        case .image(let props): return props.propsJSON
        case .icon(let props): return props.propsJSON
        case .video(let props): return props.propsJSON
        case .audioPlayer(let props): return props.propsJSON
        case .row(let props), .column(let props): return props.propsJSON
        case .list(let props): return props.propsJSON
        case .card(let props): return props.propsJSON
        case .tabs(let props): return props.propsJSON
        case .modal(let props): return props.propsJSON
        case .divider(let props): return props.propsJSON
        case .button(let props): return props.propsJSON
        case .checkBox(let props): return props.propsJSON
        case .textField(let props): return props.propsJSON
        case .dateTimeInput(let props): return props.propsJSON
        case .choicePicker(let props): return props.propsJSON
        case .slider(let props): return props.propsJSON
        case .unknown: return [:]
        }
    }
}

/// One decoded A2UI component: common metadata plus a typed body.
public struct A2UIComponent: Sendable, Hashable, Codable {
    public let id: String
    public let weight: Double?
    public let accessibility: A2UIAccessibilityAttributes?
    public let body: A2UIComponentBody

    public init(id: String,
                body: A2UIComponentBody,
                weight: Double? = nil,
                accessibility: A2UIAccessibilityAttributes? = nil) {
        self.id = id
        self.weight = weight
        self.accessibility = accessibility
        self.body = body
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.singleValueContainer()
        let value = try container.decode(JSONValue.self)
        self = try A2UIComponent.decode(json: value, allowUnknown: true)
    }

    public func encode(to encoder: any Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(jsonValue)
    }

    /// Strict Basic Catalog decode — rejects unknown kinds and unknown keys.
    ///
    /// `package`, not `public`: `JSONValue` is a wire type, so the only
    /// public way in is `Codable`. In-package callers (the wire decoders and
    /// tests) use this directly to pick the strictness they need.
    package static func decodeKnown(json: JSONValue) throws -> A2UIComponent {
        try decode(json: json, allowUnknown: false)
    }

    /// Permissive decode used for unknown catalogs — unknown kinds become opaque.
    package static func decode(json: JSONValue, allowUnknown: Bool) throws -> A2UIComponent {
        guard case .object(let object) = json else {
            throw DecodingError.dataCorrupted(.init(codingPath: [],
                                                    debugDescription: "A2UIComponent must be a JSON object"))
        }
        guard let id = object["id"]?.stringValue, !id.isEmpty else {
            throw DecodingError.dataCorrupted(.init(codingPath: [],
                                                    debugDescription: "A2UIComponent missing required string 'id'"))
        }
        guard let kindName = object["component"]?.stringValue else {
            throw DecodingError.dataCorrupted(.init(codingPath: [],
                                                    debugDescription: "A2UIComponent missing required string 'component'"))
        }
        let weight = object["weight"]?.numberValue
        let accessibility = try A2UIAccessibilityAttributes(json: object["accessibility"])
        let commonKeys: Set<String> = ["id", "component", "weight", "accessibility"]

        guard let kind = A2UIComponentBody.Kind(rawValue: kindName) else {
            guard allowUnknown else {
                throw DecodingError.dataCorrupted(.init(codingPath: [],
                                                        debugDescription: "Unknown Basic Catalog component '\(kindName)'"))
            }
            return A2UIComponent(id: id,
                                 body: .unknown(A2UIOpaqueComponent(kindName: kindName,
                                                                    raw: A2UIOpaqueJSON(json))),
                                 weight: weight,
                                 accessibility: accessibility)
        }

        let body = try decodeBody(kind: kind, object: object, commonKeys: commonKeys)
        return A2UIComponent(id: id, body: body, weight: weight, accessibility: accessibility)
    }

    package var jsonValue: JSONValue {
        if case .unknown(let opaque) = body {
            return opaque.raw.json
        }
        var object: [String: JSONValue] = [
            "id": .string(id),
            "component": .string(body.wireKindName),
        ]
        if let weight { object["weight"] = .number(weight) }
        if let accessibility { object["accessibility"] = accessibility.jsonValue }
        object.merge(body.propsJSON) { _, new in new }
        return .object(object)
    }

    private static func decodeBody(kind: A2UIComponentBody.Kind,
                                   object: [String: JSONValue],
                                   commonKeys: Set<String>) throws -> A2UIComponentBody {
        let known: Set<String>
        let body: A2UIComponentBody
        switch kind {
        case .text:
            known = commonKeys.union(["text", "variant"])
            guard let text = object["text"] else { throw missing("text") }
            body = .text(.init(text: try A2UIDynamicString(json: text),
                               variant: object["variant"]?.stringValue.flatMap(A2UITextVariant.init(rawValue:))))
        case .image:
            known = commonKeys.union(["url", "description", "fit", "variant"])
            guard let url = object["url"] else { throw missing("url") }
            body = .image(.init(url: try A2UIDynamicString(json: url),
                                description: try object["description"].map { try A2UIDynamicString(json: $0) },
                                fit: object["fit"]?.stringValue.flatMap(A2UIImageFit.init(rawValue:)),
                                variant: object["variant"]?.stringValue.flatMap(A2UIImageVariant.init(rawValue:))))
        case .icon:
            known = commonKeys.union(["name"])
            guard let name = object["name"] else { throw missing("name") }
            body = .icon(.init(name: try A2UIIconName(json: name)))
        case .video:
            known = commonKeys.union(["url"])
            guard let url = object["url"] else { throw missing("url") }
            body = .video(.init(url: try A2UIDynamicString(json: url)))
        case .audioPlayer:
            known = commonKeys.union(["url", "description"])
            guard let url = object["url"] else { throw missing("url") }
            body = .audioPlayer(.init(url: try A2UIDynamicString(json: url),
                                      description: try object["description"].map { try A2UIDynamicString(json: $0) }))
        case .row:
            known = commonKeys.union(["children", "justify", "align"])
            guard let children = object["children"] else { throw missing("children") }
            body = .row(try stackProps(children: children, object: object))
        case .column:
            known = commonKeys.union(["children", "justify", "align"])
            guard let children = object["children"] else { throw missing("children") }
            body = .column(try stackProps(children: children, object: object))
        case .list:
            known = commonKeys.union(["children", "direction", "align"])
            guard let children = object["children"] else { throw missing("children") }
            body = .list(.init(children: try A2UIChildList(json: children),
                               direction: object["direction"]?.stringValue.flatMap(A2UIListDirection.init(rawValue:)),
                               align: object["align"]?.stringValue.flatMap(A2UICrossAxisAlign.init(rawValue:))))
        case .card:
            known = commonKeys.union(["child"])
            guard let child = object["child"]?.stringValue else { throw missing("child") }
            body = .card(.init(child: child))
        case .tabs:
            known = commonKeys.union(["tabs"])
            guard let tabs = object["tabs"]?.arrayValue, !tabs.isEmpty else { throw missing("tabs") }
            body = .tabs(.init(tabs: try tabs.map { tab in
                guard case .object(let tabObject) = tab,
                      let title = tabObject["title"],
                      let child = tabObject["child"]?.stringValue else {
                    throw DecodingError.dataCorrupted(.init(codingPath: [],
                                                            debugDescription: "Tab requires title and child"))
                }
                return A2UITabItem(title: try A2UIDynamicString(json: title), child: child)
            }))
        case .modal:
            known = commonKeys.union(["trigger", "content"])
            guard let trigger = object["trigger"]?.stringValue else { throw missing("trigger") }
            guard let content = object["content"]?.stringValue else { throw missing("content") }
            body = .modal(.init(trigger: trigger, content: content))
        case .divider:
            known = commonKeys.union(["axis"])
            body = .divider(.init(axis: object["axis"]?.stringValue.flatMap(A2UIDividerAxis.init(rawValue:))))
        case .button:
            known = commonKeys.union(["child", "action", "variant", "checks"])
            guard let child = object["child"]?.stringValue else { throw missing("child") }
            guard let action = object["action"] else { throw missing("action") }
            body = .button(.init(child: child,
                                 action: try A2UIAction(json: action),
                                 variant: object["variant"]?.stringValue.flatMap(A2UIButtonVariant.init(rawValue:)),
                                 checks: try decodeChecks(object["checks"])))
        case .checkBox:
            known = commonKeys.union(["label", "value", "checks"])
            guard let label = object["label"] else { throw missing("label") }
            guard let value = object["value"] else { throw missing("value") }
            body = .checkBox(.init(label: try A2UIDynamicString(json: label),
                                   value: try A2UIDynamicBoolean(json: value),
                                   checks: try decodeChecks(object["checks"])))
        case .textField:
            known = commonKeys.union(["label", "value", "variant", "validationRegexp", "checks"])
            guard let label = object["label"] else { throw missing("label") }
            let variant = object["variant"]?.stringValue.map(A2UITextFieldVariant.init(wire:))
            body = .textField(.init(label: try A2UIDynamicString(json: label),
                                    value: try object["value"].map { try A2UIDynamicString(json: $0) },
                                    variant: variant,
                                    validationRegexp: object["validationRegexp"]?.stringValue,
                                    checks: try decodeChecks(object["checks"])))
        case .dateTimeInput:
            known = commonKeys.union(["value", "enableDate", "enableTime", "min", "max", "label", "checks"])
            guard let value = object["value"] else { throw missing("value") }
            body = .dateTimeInput(.init(value: try A2UIDynamicString(json: value),
                                        enableDate: object["enableDate"]?.boolValue,
                                        enableTime: object["enableTime"]?.boolValue,
                                        min: try object["min"].map { try A2UIDynamicString(json: $0) },
                                        max: try object["max"].map { try A2UIDynamicString(json: $0) },
                                        label: try object["label"].map { try A2UIDynamicString(json: $0) },
                                        checks: try decodeChecks(object["checks"])))
        case .choicePicker:
            known = commonKeys.union(["options", "value", "label", "variant", "displayStyle", "filterable", "checks"])
            guard let options = object["options"]?.arrayValue else { throw missing("options") }
            guard let value = object["value"] else { throw missing("value") }
            body = .choicePicker(.init(options: try options.map { option in
                guard case .object(let optionObject) = option,
                      let label = optionObject["label"],
                      let optionValue = optionObject["value"]?.stringValue else {
                    throw DecodingError.dataCorrupted(.init(codingPath: [],
                                                            debugDescription: "Choice option requires label and value"))
                }
                return A2UIChoiceOption(label: try A2UIDynamicString(json: label), value: optionValue)
            },
                                       value: try A2UIDynamicStringList(json: value),
                                       label: try object["label"].map { try A2UIDynamicString(json: $0) },
                                       variant: object["variant"]?.stringValue.flatMap(A2UIChoicePickerVariant.init(rawValue:)),
                                       displayStyle: object["displayStyle"]?.stringValue.flatMap(A2UIChoiceDisplayStyle.init(rawValue:)),
                                       filterable: object["filterable"]?.boolValue,
                                       checks: try decodeChecks(object["checks"])))
        case .slider:
            known = commonKeys.union(["value", "max", "min", "label", "checks"])
            guard let value = object["value"] else { throw missing("value") }
            guard let max = object["max"]?.numberValue else { throw missing("max") }
            body = .slider(.init(value: try A2UIDynamicNumber(json: value),
                                 max: max,
                                 min: object["min"]?.numberValue,
                                 label: try object["label"].map { try A2UIDynamicString(json: $0) },
                                 checks: try decodeChecks(object["checks"])))
        }
        for key in object.keys where !known.contains(key) {
            throw DecodingError.dataCorrupted(.init(codingPath: [],
                                                    debugDescription: "\(kind.rawValue) does not declare property '\(key)'"))
        }
        return body
    }

    private static func stackProps(children: JSONValue, object: [String: JSONValue]) throws -> A2UIStackProps {
        .init(children: try A2UIChildList(json: children),
              justify: object["justify"]?.stringValue.flatMap(A2UIMainAxisJustify.init(rawValue:)),
              align: object["align"]?.stringValue.flatMap(A2UICrossAxisAlign.init(rawValue:)))
    }

    private static func decodeChecks(_ value: JSONValue?) throws -> [A2UICheckRule]? {
        guard let value else { return nil }
        guard let array = value.arrayValue else {
            throw DecodingError.dataCorrupted(.init(codingPath: [], debugDescription: "checks must be an array"))
        }
        return try array.map { try A2UICheckRule(json: $0) }
    }

    private static func missing(_ key: String) -> DecodingError {
        .dataCorrupted(.init(codingPath: [], debugDescription: "Missing required property '\(key)'"))
    }
}

/// Typed Basic Catalog theme. Only `primaryColor` is accepted today.
public struct A2UITheme: Sendable, Hashable, Codable {
    public var primaryColor: String?

    public init(primaryColor: String? = nil) {
        self.primaryColor = primaryColor
    }

    package init(json: JSONValue) throws {
        guard case .object(let object) = json else {
            throw DecodingError.dataCorrupted(.init(codingPath: [], debugDescription: "theme must be an object"))
        }
        for key in object.keys where key != "primaryColor" {
            throw DecodingError.dataCorrupted(.init(codingPath: [],
                                                    debugDescription: "Unknown theme property '\(key)'"))
        }
        primaryColor = object["primaryColor"]?.stringValue
    }

    package var jsonValue: JSONValue {
        var object: [String: JSONValue] = [:]
        if let primaryColor { object["primaryColor"] = .string(primaryColor) }
        return .object(object)
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.singleValueContainer()
        try self.init(json: try container.decode(JSONValue.self))
    }

    public func encode(to encoder: any Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(jsonValue)
    }
}
