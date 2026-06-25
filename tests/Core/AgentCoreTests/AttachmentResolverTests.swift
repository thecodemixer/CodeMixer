import Foundation
import Testing
@testable import AgentCore
import AgentProtocol
import AgentTestSupport

@Suite("AttachmentResolver — remote upload refs")
struct AttachmentResolverTests {

    @Test("Empty refs resolve to an empty list")
    func emptyRefsResolveToEmptyList() async throws {
        let fixture = Fixture()
        let urls = try await fixture.resolver.resolve([])
        #expect(urls.isEmpty)
    }

    @Test("Exact attachment id resolves when the staged file exists")
    func exactAttachmentIDResolves() async throws {
        let fixture = Fixture()
        let exact = fixture.attachmentsDirectory.appendingPathComponent("abc123")
        try fixture.fileSystem.writeAtomically(Data("payload".utf8), to: exact)

        let urls = try await fixture.resolver.resolve([attachment("abc123")])

        #expect(urls == [exact])
    }

    @Test("Sidecar id prefix resolves to the staged file with filename suffix")
    func prefixAttachmentIDResolves() async throws {
        let fixture = Fixture()
        let staged = fixture.attachmentsDirectory.appendingPathComponent("abc123-screenshot.png")
        try fixture.fileSystem.writeAtomically(Data("png".utf8), to: staged)

        let urls = try await fixture.resolver.resolve([attachment("abc123")])

        #expect(urls == [staged])
    }

    @Test("Multiple prefix candidates are chosen deterministically by path order")
    func prefixCandidatesAreSorted() async throws {
        let fixture = Fixture()
        let first = fixture.attachmentsDirectory.appendingPathComponent("abc123-a.txt")
        let second = fixture.attachmentsDirectory.appendingPathComponent("abc123-z.txt")
        try fixture.fileSystem.writeAtomically(Data("second".utf8), to: second)
        try fixture.fileSystem.writeAtomically(Data("first".utf8), to: first)

        let urls = try await fixture.resolver.resolve([attachment("abc123")])

        #expect(urls == [first])
    }

    @Test("Multiple refs resolve in input order")
    func multipleRefsResolveInInputOrder() async throws {
        let fixture = Fixture()
        let first = fixture.attachmentsDirectory.appendingPathComponent("first-file.txt")
        let second = fixture.attachmentsDirectory.appendingPathComponent("second-file.txt")
        try fixture.fileSystem.writeAtomically(Data("1".utf8), to: first)
        try fixture.fileSystem.writeAtomically(Data("2".utf8), to: second)

        let urls = try await fixture.resolver.resolve([
            attachment("second"),
            attachment("first"),
        ])

        #expect(urls == [second, first])
    }

    @Test("Unknown attachment id throws attachmentNotFound")
    func unknownAttachmentIDThrows() async {
        let fixture = Fixture()

        do {
            _ = try await fixture.resolver.resolve([attachment("missing")])
            Issue.record("Expected attachmentNotFound to be thrown")
        } catch {
            #expect(error as? AgentError == .attachmentNotFound(id: "missing"))
        }
    }

    private func attachment(_ id: String) -> AttachmentRef {
        AttachmentRef(id: id, filename: "\(id).txt", byteCount: 1, mimeType: "text/plain")
    }

    private struct Fixture {
        let environment: FakeEnvironment
        let fileSystem: InMemoryFileSystem
        let resolver: AttachmentResolver
        let attachmentsDirectory: URL

        init() {
            environment = FakeEnvironment(home: URL(fileURLWithPath: "/tmp/attachment-resolver-home", isDirectory: true))
            fileSystem = InMemoryFileSystem()
            resolver = AttachmentResolver(environment: environment, fileSystem: fileSystem)
            attachmentsDirectory = environment.appSupportDirectory
                .appendingPathComponent("attachments", isDirectory: true)
        }
    }
}
