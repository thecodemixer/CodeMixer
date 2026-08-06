import AgentProtocol
import Foundation
import Testing
@testable import A2UICore

@Suite("A2UI surface reducer")
struct A2UISurfaceReducerTests {
    private func comp(_ json: JSONValue) -> A2UIComponent {
        // swiftlint:disable:next force_try
        try! A2UIComponent.decodeKnown(json: json)
    }

    private func batch(agentID: String = "custom-acp",
                       items: [A2UIServerBatch.Item],
                       at date: Date = Date(timeIntervalSince1970: 1_000)) -> A2UIServerBatch {
        A2UIServerBatch(
            agentID: agentID,
            transcriptKey: .init(projectRootPath: "/tmp/project", namespace: "custom-acp", sessionID: "s1"),
            resourceURI: "a2ui://migration/plan/example",
            items: items,
            recordedAt: date
        )
    }

    @Test("createSurface then updateComponents produces a renderable surface")
    func createThenUpdate() {
        let create = A2UIServerMessage.createSurface(surfaceID: "s", catalogID: A2UISchemaProfile.testScopedCatalogID,
                                                     theme: nil, sendDataModel: false)
        let root = comp(.object([
            "id": .string("root"), "component": .string("Text"), "text": .string("Hello"),
        ]))
        let update = A2UIServerMessage.updateComponents(surfaceID: "s", components: [root])
        let result = A2UISurfaceReducer.apply(batch(items: [
            .init(index: 0, message: create),
            .init(index: 1, message: update),
        ]), to: [:], at: Date())
        #expect(result.outcomes.allSatisfy { $0.applied })
        #expect(result.surfaces["s"]?.isRenderable == true)
        #expect(result.surfaces["s"]?.generation == 1)
    }

    @Test("A failed item leaves prior state unchanged and later items still apply")
    func atomicFailureContinues() {
        let create = A2UIServerMessage.createSurface(surfaceID: "s", catalogID: A2UISchemaProfile.testScopedCatalogID,
                                                     theme: nil, sendDataModel: false)
        // Empty components — rejected by the validator (strict typed decode
        // already rejects malformed components upstream at the wire boundary).
        let badUpdate = A2UIServerMessage.updateComponents(surfaceID: "s", components: [])
        let dataUpdate = A2UIServerMessage.updateDataModel(surfaceID: "s", path: "/count", value: .number(1))
        let result = A2UISurfaceReducer.apply(batch(items: [
            .init(index: 0, message: create),
            .init(index: 1, message: badUpdate),
            .init(index: 2, message: dataUpdate),
        ]), to: [:], at: Date())
        #expect(result.outcomes[0].applied)
        #expect(!result.outcomes[1].applied)
        #expect(result.outcomes[1].issue?.code == "VALIDATION_FAILED")
        #expect(result.outcomes[2].applied)
        #expect(result.surfaces["s"]?.isRenderable == false)
    }

    @Test("deleteSurface then recreate bumps the generation")
    func deleteRecreateBumpsGeneration() {
        let create = A2UIServerMessage.createSurface(surfaceID: "s", catalogID: A2UISchemaProfile.testScopedCatalogID,
                                                     theme: nil, sendDataModel: false)
        let delete = A2UIServerMessage.deleteSurface(surfaceID: "s")
        let recreate = create
        let result = A2UISurfaceReducer.apply(batch(items: [
            .init(index: 0, message: create),
        ]), to: [:], at: Date())
        #expect(result.surfaces["s"]?.generation == 1)

        let afterDelete = A2UISurfaceReducer.apply(batch(items: [.init(index: 0, message: delete)]),
                                                   to: result.surfaces,
                                                   retiredGenerations: result.retiredGenerations,
                                                   at: Date())
        #expect(afterDelete.surfaces["s"] == nil)

        let afterRecreate = A2UISurfaceReducer.apply(batch(items: [.init(index: 0, message: recreate)]),
                                                      to: afterDelete.surfaces,
                                                      retiredGenerations: afterDelete.retiredGenerations,
                                                      at: Date())
        #expect(afterRecreate.surfaces["s"]?.generation == 2)
    }

    @Test("Duplicate createSurface for a live surface is rejected")
    func duplicateCreateRejected() {
        let create = A2UIServerMessage.createSurface(surfaceID: "s", catalogID: A2UISchemaProfile.testScopedCatalogID,
                                                     theme: nil, sendDataModel: false)
        let first = A2UISurfaceReducer.apply(batch(items: [.init(index: 0, message: create)]), to: [:], at: Date())
        let second = A2UISurfaceReducer.apply(batch(items: [.init(index: 0, message: create)]),
                                              to: first.surfaces, at: Date())
        #expect(!second.outcomes[0].applied)
        #expect(second.outcomes[0].issue?.code == "DUPLICATE_SURFACE")
    }

    @Test("Unknown catalog still creates the surface for a bounded unsupported card")
    func unknownCatalogDegradesGracefully() {
        let create = A2UIServerMessage.createSurface(surfaceID: "s", catalogID: "example.com:unknown",
                                                     theme: nil, sendDataModel: false)
        let result = A2UISurfaceReducer.apply(batch(items: [.init(index: 0, message: create)]), to: [:], at: Date())
        #expect(result.outcomes[0].applied)
        #expect(result.surfaces["s"] != nil)
    }

    @Test("Migration review-duel wire JSON reduces to a renderable Codemixer surface")
    func migrationReviewDuelWireIsRenderable() throws {
        // Exact shape `migration-tool/src/acp/a2ui.ts` `reviewDuelSurface` emits
        // (including historical Material-style variants that must still map).
        let wire = """
        [
          {
            "version": "v0.9.1",
            "createSurface": {
              "surfaceId": "migration.review-duel.src_Order.cs",
              "catalogId": "\(A2UISchemaProfile.testScopedCatalogID)",
              "sendDataModel": false
            }
          },
          {
            "version": "v0.9.1",
            "updateComponents": {
              "surfaceId": "migration.review-duel.src_Order.cs",
              "components": [
                { "id": "root", "component": "Card", "child": "outer" },
                { "id": "outer", "component": "Column", "children": ["title", "row"] },
                { "id": "title", "component": "Text", "text": "Review round 1 · src/Order.cs", "variant": "titleMedium" },
                { "id": "row", "component": "Row", "children": ["a", "b"] },
                { "id": "a", "component": "Column", "children": ["a.label", "a.summary"] },
                { "id": "a.label", "component": "Text", "text": "Reviewer A", "variant": "labelMedium" },
                { "id": "a.summary", "component": "Text", "text": "approve" },
                { "id": "b", "component": "Column", "children": ["b.label", "b.finding"] },
                { "id": "b.label", "component": "Text", "text": "Reviewer B", "variant": "caption" },
                { "id": "b.finding", "component": "Text", "text": "[low] duplicate path" }
              ]
            }
          }
        ]
        """.data(using: .utf8)!

        let messages = try JSONDecoder().decode([A2UIServerMessage].self, from: wire)
        let items = messages.enumerated().map { A2UIServerBatch.Item(index: $0.offset, message: $0.element) }
        let result = A2UISurfaceReducer.apply(batch(items: items), to: [:], at: Date())
        #expect(result.outcomes.allSatisfy { $0.applied })
        let surface = try #require(result.surfaces["migration.review-duel.src_Order.cs"])
        #expect(surface.isRenderable)
        #expect(surface.rootComponentID == "root")
        guard case .text(let titleProps) = surface.components["title"]?.body else {
            Issue.record("expected title Text component")
            return
        }
        #expect(titleProps.variant == .h3)
        guard case .text(let labelProps) = surface.components["a.label"]?.body else {
            Issue.record("expected Reviewer A label")
            return
        }
        #expect(labelProps.variant == .caption)
    }

    @Test("the review duel's severity glyphs and column rule survive the wire")
    func migrationReviewDuelSeverityWireIsRenderable() throws {
        // The scannable shape `reviewDuelSurface` emits today: a vertical rule
        // between the two reviewer columns, and each finding behind a severity
        // icon whose name is what CodeMixer tints.
        let wire = """
        [
          {
            "version": "v0.9.1",
            "createSurface": {
              "surfaceId": "duel",
              "catalogId": "\(A2UISchemaProfile.testScopedCatalogID)",
              "sendDataModel": false
            }
          },
          {
            "version": "v0.9.1",
            "updateComponents": {
              "surfaceId": "duel",
              "components": [
                { "id": "root", "component": "Card", "child": "outer" },
                { "id": "outer", "component": "Column", "children": ["row"] },
                { "id": "row", "component": "Row", "children": ["a", "split", "b"] },
                { "id": "split", "component": "Divider", "axis": "vertical" },
                { "id": "a", "component": "Column", "children": ["a.verdict", "a.f0"] },
                { "id": "a.verdict", "component": "Text", "text": "Reject · 1 finding", "variant": "h5" },
                { "id": "a.f0", "component": "Row", "children": ["a.f0.icon", "a.f0.block"] },
                { "id": "a.f0.icon", "component": "Icon", "name": "error" },
                { "id": "a.f0.block", "component": "Column", "children": ["a.f0.severity", "a.f0.message"] },
                { "id": "a.f0.severity", "component": "Text", "text": "CRITICAL", "variant": "caption" },
                { "id": "a.f0.message", "component": "Text", "text": "drops the transaction" },
                { "id": "b", "component": "Column", "children": ["b.verdict"] },
                { "id": "b.verdict", "component": "Text", "text": "Approve · no findings", "variant": "h5" }
              ]
            }
          }
        ]
        """.data(using: .utf8)!

        let messages = try JSONDecoder().decode([A2UIServerMessage].self, from: wire)
        let items = messages.enumerated().map { A2UIServerBatch.Item(index: $0.offset, message: $0.element) }
        let result = A2UISurfaceReducer.apply(batch(items: items), to: [:], at: Date())
        #expect(result.outcomes.allSatisfy { $0.applied })
        let surface = try #require(result.surfaces["duel"])
        #expect(surface.isRenderable)
        guard case .divider(let splitProps) = surface.components["split"]?.body else {
            Issue.record("expected the column split to decode as a Divider")
            return
        }
        #expect(splitProps.axis == .vertical)
        guard case .icon(let iconProps) = surface.components["a.f0.icon"]?.body else {
            Issue.record("expected a severity Icon")
            return
        }
        #expect(iconProps.name.catalogSymbol == "error")
        guard case .text(let verdictProps) = surface.components["a.verdict"]?.body else {
            Issue.record("expected a verdict headline")
            return
        }
        #expect(verdictProps.variant == .h5)
    }
}
