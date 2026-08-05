import AgentProtocol
import Foundation
import Testing
@testable import A2UICore

@Suite("A2UI action resolver — trust boundary")
struct A2UIActionResolverTests {

    @Test("resolves event name and context from a Button action on the canonical surface")
    func resolvesEventAction() {
        let surface = makeSurface(generation: 1)
        let intent = intent(generation: 1, componentID: "btn")
        let result = A2UIActionResolver.resolve(intent, against: surface, now: Date(timeIntervalSince1970: 42))
        guard case .success(let resolution) = result else {
            Issue.record("expected success, got \(result)")
            return
        }
        #expect(resolution.name == "migrationReviewDecision")
        #expect(resolution.context["optionId"]?.stringValue == "accept_a")
        #expect(resolution.context["nonce"]?.stringValue == "n1")
    }

    @Test("rejects when the surface is missing")
    func surfaceNotFound() {
        let intent = intent(generation: 1, componentID: "btn")
        guard case .failure(.surfaceNotFound) = A2UIActionResolver.resolve(intent, against: nil) else {
            Issue.record("expected surfaceNotFound")
            return
        }
    }

    @Test("rejects a stale generation after delete-then-recreate")
    func generationMismatch() {
        let surface = makeSurface(generation: 2)
        let intent = intent(generation: 1, componentID: "btn")
        guard case .failure(.generationMismatch) = A2UIActionResolver.resolve(intent, against: surface) else {
            Issue.record("expected generationMismatch")
            return
        }
    }

    @Test("rejects an unknown source component id")
    func componentNotFound() {
        let surface = makeSurface(generation: 1)
        let intent = intent(generation: 1, componentID: "missing")
        guard case .failure(.componentNotFound) = A2UIActionResolver.resolve(intent, against: surface) else {
            Issue.record("expected componentNotFound")
            return
        }
    }

    @Test("rejects a Text component that has no dispatchable event action")
    func notAnEventAction() {
        let surface = makeSurface(generation: 1)
        let intent = intent(generation: 1, componentID: "root")
        guard case .failure(.notAnEventAction) = A2UIActionResolver.resolve(intent, against: surface) else {
            Issue.record("expected notAnEventAction")
            return
        }
    }

    // MARK: - Fixtures

    private func comp(_ json: JSONValue) -> A2UIComponent {
        // swiftlint:disable:next force_try
        try! A2UIComponent.decodeKnown(json: json)
    }

    private func makeSurface(generation: Int) -> A2UISurfaceState {
        var surface = A2UISurfaceState(
            surfaceID: "s",
            agentID: "other",
            catalogID: A2UISchemaProfile.testScopedCatalogID,
            theme: nil,
            sendDataModel: false,
            generation: generation,
            createdAt: Date(timeIntervalSince1970: 1)
        )
        let root = comp(.object([
            "id": .string("root"),
            "component": .string("Column"),
            "children": .array([.string("btn")]),
        ]))
        let label = comp(.object([
            "id": .string("btn-label"),
            "component": .string("Text"),
            "text": .string("Accept"),
        ]))
        let button = comp(.object([
            "id": .string("btn"),
            "component": .string("Button"),
            "child": .string("btn-label"),
            "action": .object([
                "event": .object([
                    "name": .string("migrationReviewDecision"),
                    "context": .object([
                        "optionId": .string("accept_a"),
                        "nonce": .string("n1"),
                    ]),
                ]),
            ]),
        ]))
        surface.replaceComponents([root, label, button], at: Date(timeIntervalSince1970: 1))
        return surface
    }

    private func intent(generation: Int, componentID: String) -> A2UIInteractionIntent {
        A2UIInteractionIntent(
            transcriptKey: .init(projectRootPath: "/tmp/project", namespace: "other", sessionID: "s1"),
            agentID: "other",
            surfaceID: "s",
            generation: generation,
            sourceComponentID: componentID,
            occurredAt: Date(timeIntervalSince1970: 2)
        )
    }
}
