import AgentProtocol
import Testing
@testable import A2UICore

@Suite("A2UI JSON Pointer navigation")
struct A2UIJSONPointerTests {
    @Test("Root pointer resolves to the whole document")
    func rootPointer() {
        let root: A2UIResolvedValue = .object(["a": .number(1)])
        #expect(A2UIJSONPointer.value(at: "", in: root) == root)
        #expect(A2UIJSONPointer.value(at: "/", in: root) == root)
    }

    @Test("Nested object and array navigation")
    func nestedNavigation() {
        let root: A2UIResolvedValue = .object([
            "user": .object(["name": .string("Ada")]),
            "items": .array([.string("a"), .string("b")]),
        ])
        #expect(A2UIJSONPointer.value(at: "/user/name", in: root) == .string("Ada"))
        #expect(A2UIJSONPointer.value(at: "/items/1", in: root) == .string("b"))
        #expect(A2UIJSONPointer.value(at: "/items/5", in: root) == nil)
    }

    @Test("Escaped tokens per RFC 6901")
    func escapedTokens() {
        let root: A2UIResolvedValue = .object(["a/b": .string("slash"), "c~d": .string("tilde")])
        #expect(A2UIJSONPointer.value(at: "/a~1b", in: root) == .string("slash"))
        #expect(A2UIJSONPointer.value(at: "/c~0d", in: root) == .string("tilde"))
    }

    @Test("Setting a nested path creates intermediate objects")
    func settingCreatesIntermediates() {
        let result = A2UIJSONPointer.setting(at: "/a/b/c", to: .number(42), in: .object([:]))
        #expect(A2UIJSONPointer.value(at: "/a/b/c", in: result) == .number(42))
    }

    @Test("Setting nil removes an object key but preserves array indexes as null")
    func removalSemantics() {
        let withKey = A2UIJSONPointer.setting(at: "/k", to: .string("v"), in: .object([:]))
        let removed = A2UIJSONPointer.setting(at: "/k", to: nil, in: withKey)
        #expect(A2UIJSONPointer.value(at: "/k", in: removed) == nil)

        let array = A2UIJSONPointer.setting(at: "/0", to: .string("x"), in: .array([]))
        let arrayRemoved = A2UIJSONPointer.setting(at: "/0", to: nil, in: array)
        #expect(A2UIJSONPointer.value(at: "/0", in: arrayRemoved) == .null)
    }

    @Test("Relative pointers resolve against the innermost repeated-list scope")
    func scopedResolution() {
        #expect(A2UIJSONPointer.resolveScoped("name", scopePaths: ["/items/2"]) == "/items/2/name")
        #expect(A2UIJSONPointer.resolveScoped("/absolute", scopePaths: ["/items/2"]) == "/absolute")
        #expect(A2UIJSONPointer.resolveScoped("name", scopePaths: []) == "/name")
    }
}
