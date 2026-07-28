/// Imports Cursor chat metadata and visible message leaves from its
/// vendor-owned per-project SQLite stores.
import Foundation

import AgentCore

struct CursorSessionCatalogImporter: Sendable {
    private let fileSystem: any FileSystem
    private let sqlite: any SQLiteReading
    private let homeDirectory: URL
    private let random: any RandomSource

    init(homeDirectory: URL,
         fileSystem: any FileSystem,
         sqlite: any SQLiteReading = SQLiteReader(),
         random: any RandomSource = SystemRandomSource()) {
        self.homeDirectory = homeDirectory
        self.fileSystem = fileSystem
        self.sqlite = sqlite
        self.random = random
    }

    func sessions(
        workspace: URL,
        progress: @escaping @Sendable (Int, Int) async -> Void
    ) async throws -> [ImportedSession] {
        let candidates = CursorWorkspaceIdentity.chatsDirectories(
            forWorkspace: workspace,
            cursorDirectory: cursorDirectory
        ).flatMap { projectDirectory in
            ((try? fileSystem.contentsOfDirectory(at: projectDirectory)) ?? [])
                .map { chatDirectory in
                    CursorWorkspaceIdentity.storeURL(
                        chatID: chatDirectory.lastPathComponent,
                        in: projectDirectory
                    )
                }
                .filter { fileSystem.fileExists(at: $0) }
        }
        var imported: [ImportedSession] = []
        for (offset, storeURL) in candidates.enumerated() {
            if Task.isCancelled { break }
            if let session = try session(from: storeURL) {
                imported.append(session)
            }
            await progress(offset + 1, candidates.count)
        }
        return imported.sorted {
            ($0.lastActivity ?? .distantPast) > ($1.lastActivity ?? .distantPast)
        }
    }

    private func session(from storeURL: URL) throws -> ImportedSession? {
        let rows = try sqlite.rows(
            in: storeURL,
            query: "SELECT value FROM meta WHERE key = ? LIMIT 1",
            textBindings: ["0"]
        )
        guard let value = rows.first?["value"],
              let metadata = Self.decodeMetadata(value) else {
            return nil
        }
        let fallbackID = storeURL.deletingLastPathComponent().lastPathComponent
        let id = metadata.agentID.isEmpty ? fallbackID : metadata.agentID
        let createdAt = metadata.createdAt.map {
            Date(timeIntervalSince1970: $0 / 1_000)
        }
        let lastActivity = (try? fileSystem.modificationDate(at: storeURL)) ?? createdAt
        let events = try metadata.latestRootBlobID.map {
            try CursorTranscriptDecoder(sqlite: sqlite, random: random).events(
                databaseURL: storeURL,
                rootBlobID: $0,
                sessionID: id,
                timestamp: lastActivity ?? .distantPast
            )
        } ?? []
        return ImportedSession(
            id: id,
            title: metadata.name,
            lastActivity: lastActivity,
            events: events
        )
    }

    private var cursorDirectory: URL {
        homeDirectory.appendingPathComponent(".cursor", isDirectory: true)
    }

    private static func decodeMetadata(_ stored: Data) -> CursorChatMetadata? {
        if let decoded = try? JSONDecoder().decode(CursorChatMetadata.self, from: stored) {
            return decoded
        }
        guard let hex = String(data: stored, encoding: .utf8),
              let data = Data(hexEncoded: hex) else {
            return nil
        }
        return try? JSONDecoder().decode(CursorChatMetadata.self, from: data)
    }
}

private struct CursorChatMetadata: Decodable {
    let agentID: String
    let name: String?
    let createdAt: Double?
    let latestRootBlobID: String?

    private enum CodingKeys: String, CodingKey {
        case agentID = "agentId"
        case name, createdAt
        case latestRootBlobID = "latestRootBlobId"
    }

    init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        agentID = try container.decode(String.self, forKey: .agentID)
        name = try container.decodeIfPresent(String.self, forKey: .name)
        latestRootBlobID = try container.decodeIfPresent(String.self,
                                                         forKey: .latestRootBlobID)
        if let number = try? container.decode(Double.self, forKey: .createdAt) {
            createdAt = number
        } else if let text = try? container.decode(String.self, forKey: .createdAt) {
            createdAt = Double(text)
        } else {
            createdAt = nil
        }
    }
}

private extension Data {
    init?(hexEncoded value: String) {
        let hex = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard hex.count.isMultiple(of: 2) else { return nil }
        var bytes: [UInt8] = []
        bytes.reserveCapacity(hex.count / 2)
        var index = hex.startIndex
        while index < hex.endIndex {
            let end = hex.index(index, offsetBy: 2)
            guard let byte = UInt8(hex[index ..< end], radix: 16) else { return nil }
            bytes.append(byte)
            index = end
        }
        self.init(bytes)
    }
}
