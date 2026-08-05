import AgentProtocol
import Foundation
import Testing
@testable import A2UICore

/// Covers the typed wire codec for `A2UIComponent`: strict Basic Catalog
/// decoding for known kinds, and lossless opaque replay for anything the
/// pinned catalog does not describe.
@Suite("A2UI component wire codec — typed decode and opaque replay")
struct A2UIComponentCodableTests {
    private func encodeToJSON(_ component: A2UIComponent) throws -> JSONValue {
        let data = try JSONEncoder().encode(component)
        return try JSONDecoder().decode(JSONValue.self, from: data)
    }

    private func decode(_ json: JSONValue) throws -> A2UIComponent {
        let data = try JSONEncoder().encode(json)
        return try JSONDecoder().decode(A2UIComponent.self, from: data)
    }

    // MARK: - Known components

    @Test("Every Basic Catalog component round-trips through Codable unchanged")
    func knownComponentsRoundTrip() throws {
        let fixtures: [JSONValue] = [
            .object(["id": .string("t"), "component": .string("Text"),
                     "text": .string("hello"), "variant": .string("caption")]),
            .object(["id": .string("t2"), "component": .string("Text"),
                     "text": .object(["path": .string("/name")])]),
            .object(["id": .string("img"), "component": .string("Image"),
                     "url": .string("https://example.com/a.png"),
                     "description": .string("alt"), "fit": .string("cover"),
                     "variant": .string("avatar")]),
            .object(["id": .string("ic"), "component": .string("Icon"), "name": .string("home")]),
            .object(["id": .string("ic2"), "component": .string("Icon"),
                     "name": .object(["svgPath": .string("M0 0")])]),
            .object(["id": .string("vid"), "component": .string("Video"),
                     "url": .string("https://example.com/v.mp4")]),
            .object(["id": .string("aud"), "component": .string("AudioPlayer"),
                     "url": .string("https://example.com/a.mp3"), "description": .string("clip")]),
            .object(["id": .string("row"), "component": .string("Row"),
                     "children": .array([.string("a"), .string("b")]),
                     "justify": .string("spaceBetween"), "align": .string("center")]),
            .object(["id": .string("col"), "component": .string("Column"),
                     "children": .object(["componentId": .string("tpl"), "path": .string("/items")])]),
            .object(["id": .string("lst"), "component": .string("List"),
                     "children": .array([.string("a")]), "direction": .string("horizontal"),
                     "align": .string("start")]),
            .object(["id": .string("card"), "component": .string("Card"), "child": .string("inner")]),
            .object(["id": .string("tabs"), "component": .string("Tabs"),
                     "tabs": .array([.object(["title": .string("One"), "child": .string("c1")])])]),
            .object(["id": .string("modal"), "component": .string("Modal"),
                     "trigger": .string("btn"), "content": .string("body")]),
            .object(["id": .string("div"), "component": .string("Divider"), "axis": .string("vertical")]),
            .object(["id": .string("btn"), "component": .string("Button"),
                     "child": .string("label"),
                     "action": .object(["event": .object([
                         "name": .string("decide"),
                         "context": .object(["optionId": .string("a")]),
                     ])]),
                     "variant": .string("primary"),
                     "checks": .array([.object([
                         "condition": .object(["path": .string("/ok")]),
                         "message": .string("required"),
                     ])])]),
            .object(["id": .string("cb"), "component": .string("CheckBox"),
                     "label": .string("Agree"), "value": .bool(true)]),
            .object(["id": .string("tf"), "component": .string("TextField"),
                     "label": .string("Name"), "value": .object(["path": .string("/name")]),
                     "variant": .string("longText"), "validationRegexp": .string("^.+$")]),
            .object(["id": .string("dt"), "component": .string("DateTimeInput"),
                     "value": .object(["path": .string("/when")]),
                     "enableDate": .bool(true), "enableTime": .bool(false),
                     "min": .string("2020-01-01"), "max": .string("2030-01-01"),
                     "label": .string("When")]),
            .object(["id": .string("cp"), "component": .string("ChoicePicker"),
                     "options": .array([.object(["label": .string("A"), "value": .string("a")])]),
                     "value": .array([.string("a")]),
                     "label": .string("Pick"), "variant": .string("multipleSelection"),
                     "displayStyle": .string("chips"), "filterable": .bool(true)]),
            .object(["id": .string("sl"), "component": .string("Slider"),
                     "value": .number(5), "max": .number(10), "min": .number(1),
                     "label": .string("Level")]),
        ]

        for fixture in fixtures {
            let component = try A2UIComponent.decodeKnown(json: fixture)
            #expect(!component.body.isUnknown)
            // Re-encoding reproduces the exact wire object it decoded from.
            #expect(try encodeToJSON(component) == fixture)
            // And a second decode of that output is value-identical.
            #expect(try decode(encodeToJSON(component)) == component)
        }
    }

    @Test("Common fields (weight and accessibility) survive the round-trip")
    func commonFieldsRoundTrip() throws {
        let json: JSONValue = .object([
            "id": .string("t"),
            "component": .string("Text"),
            "text": .string("hi"),
            "weight": .number(2),
            "accessibility": .object(["label": .string("greeting"),
                                      "description": .object(["path": .string("/desc")])]),
        ])
        let component = try A2UIComponent.decodeKnown(json: json)
        #expect(component.weight == 2)
        #expect(component.accessibility?.label == .literal("greeting"))
        #expect(component.accessibility?.description == .binding(A2UIDataBinding(path: "/desc")))
        #expect(try encodeToJSON(component) == json)
    }

    @Test("Typed body decodes into the matching props rather than a property bag")
    func typedBodyPayload() throws {
        let component = try A2UIComponent.decodeKnown(json: .object([
            "id": .string("btn"), "component": .string("Button"),
            "child": .string("label"),
            "action": .object(["event": .object(["name": .string("decide")])]),
        ]))
        guard case .button(let props) = component.body else {
            Issue.record("expected a typed button body")
            return
        }
        #expect(props.child == "label")
        #expect(props.action == .event(name: "decide", context: [:]))
        #expect(component.body.kind == .button)
        #expect(component.body.wireKindName == A2UIComponentBody.Kind.button.rawValue)
    }

    @Test("Body.Kind is the single vocabulary for known wire discriminants")
    func bodyKindIsSingleVocabulary() {
        #expect(A2UIComponentBody.Kind(rawValue: "Button") == .button)
        #expect(A2UIComponentBody.Kind(rawValue: "HoloDeck") == nil)
        #expect(Set(A2UIComponentBody.Kind.allCases.map(\.rawValue)).count
            == A2UIComponentBody.Kind.allCases.count)
    }

    // MARK: - Strictness

    @Test("Strict decode rejects a missing required property")
    func strictRejectsMissingRequired() {
        #expect(throws: (any Error).self) {
            _ = try A2UIComponent.decodeKnown(json: .object([
                "id": .string("t"), "component": .string("Text"),
            ]))
        }
    }

    @Test("Strict decode rejects a property the component does not declare")
    func strictRejectsUndeclaredProperty() {
        #expect(throws: (any Error).self) {
            _ = try A2UIComponent.decodeKnown(json: .object([
                "id": .string("t"), "component": .string("Text"),
                "text": .string("hi"), "nope": .string("x"),
            ]))
        }
    }

    @Test("Strict decode rejects an unknown component kind")
    func strictRejectsUnknownKind() {
        #expect(throws: (any Error).self) {
            _ = try A2UIComponent.decodeKnown(json: .object([
                "id": .string("x"), "component": .string("HoloDeck"),
            ]))
        }
    }

    @Test("Strict decode requires a non-empty id")
    func strictRequiresID() {
        #expect(throws: (any Error).self) {
            _ = try A2UIComponent.decodeKnown(json: .object([
                "id": .string(""), "component": .string("Text"), "text": .string("hi"),
            ]))
        }
    }

    // MARK: - Opaque unknown replay

    @Test("Unknown component kind becomes opaque and re-encodes byte-for-byte")
    func unknownKindIsLossless() throws {
        let json: JSONValue = .object([
            "id": .string("x"),
            "component": .string("HoloDeck"),
            "deck": .object(["rows": .array([.number(1), .number(2)]),
                             "nested": .object(["deep": .bool(true)])]),
            "unmodelled": .null,
        ])
        let component = try A2UIComponent.decode(json: json, allowUnknown: true)
        #expect(component.id == "x")
        #expect(component.body.isUnknown)
        #expect(component.body.wireKindName == "HoloDeck")
        // Lossless: nothing about the unknown payload is dropped or reordered.
        #expect(try encodeToJSON(component) == json)
    }

    @Test("Opaque components survive a full Codable round-trip through A2UIServerMessage")
    func opaqueSurvivesServerMessageRoundTrip() throws {
        let unknown: JSONValue = .object([
            "id": .string("x"), "component": .string("HoloDeck"),
            "payload": .object(["k": .string("v")]),
        ])
        let message = A2UIServerMessage.updateComponents(
            surfaceID: "s",
            components: [try A2UIComponent.decode(json: unknown, allowUnknown: true)]
        )
        let data = try JSONEncoder().encode(message)
        let decoded = try JSONDecoder().decode(A2UIServerMessage.self, from: data)
        guard case .updateComponents(let surfaceID, let components) = decoded else {
            Issue.record("expected updateComponents")
            return
        }
        #expect(surfaceID == "s")
        #expect(components.count == 1)
        #expect(components[0].body.isUnknown)
        #expect(try encodeToJSON(components[0]) == unknown)
    }

    @Test("Codable decoding is permissive so an unknown kind never fails the batch")
    func codableIsPermissive() throws {
        let component = try decode(.object([
            "id": .string("x"), "component": .string("HoloDeck"),
        ]))
        #expect(component.body.isUnknown)
    }

    // MARK: - Unknown catalog opacity

    @Test("A surface on an unknown catalog stores even known kinds opaquely, losslessly")
    func unknownCatalogForcesOpacity() throws {
        var surface = A2UISurfaceState(
            surfaceID: "s",
            agentID: "a",
            catalogID: "example.com:unknown",
            theme: nil,
            sendDataModel: false,
            generation: 1,
            createdAt: Date(timeIntervalSince1970: 1)
        )
        let textJSON: JSONValue = .object([
            "id": .string("root"), "component": .string("Text"), "text": .string("hello"),
        ])
        surface.replaceComponents([try A2UIComponent.decodeKnown(json: textJSON)],
                                  at: Date(timeIntervalSince1970: 1))
        let stored = try #require(surface.components["root"])
        // Known kind, unknown catalog: kept opaque so we never render a
        // Basic Catalog component we were not told to render.
        #expect(stored.body.isUnknown)
        #expect(stored.body.wireKindName == "Text")
        #expect(try encodeToJSON(stored) == textJSON)
    }

    @Test("A surface on the pinned catalog keeps components typed")
    func knownCatalogKeepsTypedBodies() throws {
        var surface = A2UISurfaceState(
            surfaceID: "s",
            agentID: "a",
            catalogID: A2UISchemaProfile.testScopedCatalogID,
            theme: nil,
            sendDataModel: false,
            generation: 1,
            createdAt: Date(timeIntervalSince1970: 1)
        )
        surface.replaceComponents([try A2UIComponent.decodeKnown(json: .object([
            "id": .string("root"), "component": .string("Text"), "text": .string("hello"),
        ]))], at: Date(timeIntervalSince1970: 1))
        let stored = try #require(surface.components["root"])
        #expect(!stored.body.isUnknown)
        guard case .text(let props) = stored.body else {
            Issue.record("expected a typed text body")
            return
        }
        #expect(props.text == .literal("hello"))
    }

    // MARK: - Theme

    @Test("Theme round-trips and rejects unknown keys")
    func themeCodec() throws {
        let theme = try A2UITheme(json: .object(["primaryColor": .string("#112233")]))
        #expect(theme.primaryColor == "#112233")
        #expect(throws: (any Error).self) {
            _ = try A2UITheme(json: .object(["primaryColor": .string("#fff"), "spooky": .bool(true)]))
        }
    }
}
