import AgentProtocol
import Foundation
import Testing
@testable import A2UICore

@Suite("A2UI text summary — search and export plaintext")
struct A2UITextSummaryTests {

    @Test("walks Text nodes from root and skips Button chrome")
    func collectsTextFromTree() {
        let surface = makeSurface(texts: ["Review required", "Accept A"])
        let summary = A2UITextSummary.summary(for: surface)
        #expect(summary.contains("Review required"))
        #expect(summary.contains("Accept A"))
        #expect(!summary.contains("migrationReviewDecision"))
    }

    @Test("returns a placeholder when the surface has no root yet")
    func emptySurfacePlaceholder() {
        let surface = A2UISurfaceState(
            surfaceID: "empty",
            agentID: "other",
            catalogID: A2UISchemaProfile.testScopedCatalogID,
            theme: nil,
            sendDataModel: false,
            generation: 1,
            createdAt: Date(timeIntervalSince1970: 1)
        )
        #expect(A2UITextSummary.summary(for: surface).contains("empty"))
        #expect(A2UITextSummary.summary(for: surface).contains("no content yet"))
    }

    @Test("truncates at maxLength with an ellipsis")
    func truncatesLongSummary() {
        let surface = makeSurface(texts: [String(repeating: "x", count: 200)])
        let summary = A2UITextSummary.summary(for: surface, maxLength: 40)
        #expect(summary.count == 41) // 40 chars + ellipsis
        #expect(summary.hasSuffix("…"))
    }

    @Test("walks a repeated-list template's component so its text is still searchable")
    func collectsTextFromTemplateChildList() {
        var surface = A2UISurfaceState(
            surfaceID: "s",
            agentID: "other",
            catalogID: A2UISchemaProfile.testScopedCatalogID,
            theme: nil,
            sendDataModel: false,
            generation: 1,
            createdAt: Date(timeIntervalSince1970: 1)
        )
        surface.replaceComponents([
            comp(.object([
                "id": .string("root"),
                "component": .string("Column"),
                "children": .object(["componentId": .string("tpl"), "path": .string("/items")]),
            ])),
            comp(.object([
                "id": .string("tpl"),
                "component": .string("Text"),
                "text": .string("Per-item label"),
            ])),
        ], at: Date(timeIntervalSince1970: 1))

        #expect(A2UITextSummary.summary(for: surface).contains("Per-item label"))
    }

    private func comp(_ json: JSONValue) -> A2UIComponent {
        // swiftlint:disable:next force_try
        try! A2UIComponent.decodeKnown(json: json)
    }

    private func makeSurface(texts: [String]) -> A2UISurfaceState {
        var children: [JSONValue] = []
        var components: [A2UIComponent] = []
        for (index, text) in texts.enumerated() {
            let id = "t\(index)"
            children.append(.string(id))
            components.append(comp(.object([
                "id": .string(id),
                "component": .string("Text"),
                "text": .string(text),
            ])))
        }
        components.insert(comp(.object([
            "id": .string("root"),
            "component": .string("Column"),
            "children": .array(children),
        ])), at: 0)

        var surface = A2UISurfaceState(
            surfaceID: "s",
            agentID: "other",
            catalogID: A2UISchemaProfile.testScopedCatalogID,
            theme: nil,
            sendDataModel: false,
            generation: 1,
            createdAt: Date(timeIntervalSince1970: 1)
        )
        surface.replaceComponents(components, at: Date(timeIntervalSince1970: 1))
        return surface
    }
}
