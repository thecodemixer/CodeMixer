import Foundation
import Testing
@testable import AgentCore

@Suite("WebPageEntry normalization")
struct WebPagesProjectTests {
    @Test("prepends https when scheme is missing")
    func prependsHTTPS() {
        let pages = WebPageEntry.normalized([
            WebPageEntry(displayName: "Example", urlString: "example.com/app")
        ])
        #expect(pages.count == 1)
        #expect(pages[0].urlString.hasPrefix("https://example.com"))
    }

    @Test("rejects non-http schemes")
    func rejectsNonHTTP() {
        let pages = WebPageEntry.normalized([
            WebPageEntry(displayName: "File", urlString: "file:///tmp/x"),
            WebPageEntry(displayName: "JS", urlString: "javascript:alert(1)"),
            WebPageEntry(displayName: "FTP", urlString: "ftp://example.com"),
        ])
        #expect(pages.isEmpty)
    }

    @Test("dedupes by case-insensitive URL and caps at maxPages")
    func dedupeAndCap() {
        var drafts: [WebPageEntry] = [
            WebPageEntry(displayName: "A", urlString: "https://Example.com/a"),
            WebPageEntry(displayName: "B", urlString: "https://example.com/a"),
        ]
        for i in 0..<25 {
            drafts.append(WebPageEntry(displayName: "P\(i)", urlString: "https://host.example/\(i)"))
        }
        let pages = WebPageEntry.normalized(drafts)
        #expect(pages.count == WebPageEntry.maxPages)
        #expect(pages.filter { $0.urlString.lowercased().contains("example.com/a") }.count == 1)
    }

    @Test("empty display name falls back to host")
    func emptyNameUsesHost() {
        let pages = WebPageEntry.normalized([
            WebPageEntry(displayName: "  ", urlString: "https://docs.example.com/path")
        ])
        #expect(pages.count == 1)
        #expect(pages[0].displayName == "docs.example.com")
    }

    @Test("config Codable round-trip preserves session store id")
    func configRoundTrip() throws {
        let id = UUID()
        let config = WebPagesProjectConfig(
            pages: [
                WebPageEntry(displayName: "App", urlString: "https://app.example.com")
            ],
            sessionStoreIdentifier: id
        )
        let data = try JSONEncoder().encode(config)
        let decoded = try JSONDecoder().decode(WebPagesProjectConfig.self, from: data)
        #expect(decoded.sessionStoreIdentifier == id)
        #expect(decoded.pages.count == 1)
        #expect(decoded.pages[0].displayName == "App")
    }

    @Test("ProjectType.webPages is non-agent")
    func projectTypeFlags() {
        let type = ProjectType.webPages
        #expect(type.isWebPagesBacked)
        #expect(!type.isAgentBacked)
        #expect(!type.isFolderBacked)
        #expect(type.primaryAgentID == nil)
        #expect(type.shortLabel == "Web")
        #expect(!type.showsSidebarTypeCapsule)
        #expect(ProjectAgentRouter.resolveAdapterID(projectType: type) == nil)
    }
}
