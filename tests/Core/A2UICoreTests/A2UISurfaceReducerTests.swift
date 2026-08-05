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
}
