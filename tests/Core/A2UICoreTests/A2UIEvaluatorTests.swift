import AgentProtocol
import Testing
@testable import A2UICore

@Suite("A2UI evaluator")
struct A2UIEvaluatorTests {
    /// Wire JSON → typed data document (package init, in-package test only).
    private func doc(_ json: JSONValue) -> A2UIDataDocument { A2UIDataDocument(json: json) }
    /// Wire JSON → typed dynamic expression (package init, in-package test only).
    private func expr(_ json: JSONValue) throws -> A2UIDynamicValue { try A2UIDynamicValue(json: json) }

    @Test("Literal values resolve unchanged")
    func literals() throws {
        var evaluator = A2UIEvaluator(dataModel: doc(.object([:])))
        #expect(try evaluator.resolve(expr(.string("hi"))) == .string("hi"))
        #expect(try evaluator.resolve(expr(.number(3))) == .number(3))
    }

    @Test("DataBinding resolves against the data model")
    func dataBinding() throws {
        var evaluator = A2UIEvaluator(dataModel: doc(.object(["name": .string("Ada")])))
        let resolved = try evaluator.resolve(expr(.object(["path": .string("/name")])))
        #expect(resolved == .string("Ada"))
    }

    @Test("Local overlay values take precedence over the canonical data model")
    func overlayPrecedence() throws {
        var evaluator = A2UIEvaluator(dataModel: doc(.object(["name": .string("Ada")])),
                                      overlay: ["/name": .string("Grace")])
        #expect(try evaluator.resolveString(expr(.object(["path": .string("/name")]))) == "Grace")
    }

    @Test("Relative bindings resolve against repeated-list scope")
    func repeatedListScope() throws {
        let model: JSONValue = .object(["items": .array([
            .object(["label": .string("first")]),
            .object(["label": .string("second")]),
        ])])
        var evaluator = A2UIEvaluator(dataModel: doc(model), scopePaths: ["/items/1"])
        #expect(try evaluator.resolveString(expr(.object(["path": .string("label")]))) == "second")
    }

    @Test("required / regex / length / numeric / email functions")
    func validationFunctions() throws {
        var evaluator = A2UIEvaluator(dataModel: doc(.object([:])))
        #expect(try evaluator.resolveBool(expr(.object(["call": .string("required"), "args": .object(["value": .string("x")])]))))
        #expect(try !evaluator.resolveBool(expr(.object(["call": .string("required"), "args": .object(["value": .string("")])]))))
        #expect(try evaluator.resolveBool(expr(.object([
            "call": .string("regex"),
            "args": .object(["value": .string("abc123"), "pattern": .string("^[a-z]+[0-9]+$")]),
        ]))))
        #expect(try evaluator.resolveBool(expr(.object([
            "call": .string("length"),
            "args": .object(["value": .string("hello"), "min": .number(3), "max": .number(10)]),
        ]))))
        #expect(try evaluator.resolveBool(expr(.object([
            "call": .string("numeric"),
            "args": .object(["value": .number(5), "min": .number(0), "max": .number(10)]),
        ]))))
        #expect(try evaluator.resolveBool(expr(.object([
            "call": .string("email"),
            "args": .object(["value": .string("a@b.com")]),
        ]))))
        #expect(try !evaluator.resolveBool(expr(.object([
            "call": .string("email"),
            "args": .object(["value": .string("not-an-email")]),
        ]))))
    }

    @Test("and / or / not compose boolean checks")
    func logicalFunctions() throws {
        var evaluator = A2UIEvaluator(dataModel: doc(.object([:])))
        let trueValue = JSONValue.bool(true)
        let falseValue = JSONValue.bool(false)
        #expect(try evaluator.resolveBool(expr(.object(["call": .string("and"), "args": .object(["values": .array([trueValue, trueValue])])]))))
        #expect(try !evaluator.resolveBool(expr(.object(["call": .string("and"), "args": .object(["values": .array([trueValue, falseValue])])]))))
        #expect(try evaluator.resolveBool(expr(.object(["call": .string("or"), "args": .object(["values": .array([falseValue, trueValue])])]))))
        #expect(try evaluator.resolveBool(expr(.object(["call": .string("not"), "args": .object(["value": falseValue])]))))
    }

    @Test("formatString interpolates data model paths")
    func formatStringInterpolation() throws {
        var evaluator = A2UIEvaluator(dataModel: doc(.object(["count": .number(3)])))
        let result = try evaluator.resolveString(expr(.object([
            "call": .string("formatString"),
            "args": .object(["value": .string("Count: ${/count}")]),
        ])))
        #expect(result == "Count: 3")
    }

    @Test("pluralize returns 'other' fallback when category string is absent")
    func pluralizeFallback() throws {
        var evaluator = A2UIEvaluator(dataModel: doc(.object([:])))
        let result = try evaluator.resolveString(expr(.object([
            "call": .string("pluralize"),
            "args": .object(["value": .number(5), "other": .string("items")]),
        ])))
        #expect(result == "items")
    }

    @Test("openUrl cannot be used as a value expression")
    func voidFunctionRejected() throws {
        var evaluator = A2UIEvaluator(dataModel: doc(.object([:])))
        let call = try expr(.object(["call": .string("openUrl"), "args": .object(["url": .string("https://example.com")])]))
        #expect(throws: A2UIEvaluator.EvaluationError.voidFunctionUsedAsValue(.openUrl)) {
            _ = try evaluator.resolve(call)
        }
    }

    @Test("Unknown function names are rejected")
    func unknownFunctionRejected() throws {
        var evaluator = A2UIEvaluator(dataModel: doc(.object([:])))
        // `nope` is not a catalog function; decoding rejects it before evaluation.
        #expect(throws: (any Error).self) {
            _ = try evaluator.resolve(expr(.object(["call": .string("nope"), "args": .object([:])])))
        }
    }
}
