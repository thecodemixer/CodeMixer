import Foundation

/// Opaque reference to an attachment uploaded via `POST /v1/attachments`.
///
/// Clients pass these in `AgentCommand.sendPrompt(attachments:)`. The server
/// resolves them to staged files under `~/Library/Caches/Codemixer/uploads/`.
public struct AttachmentRef: Sendable, Codable, Hashable, Identifiable {
    public let id: String
    public let filename: String
    public let byteCount: Int
    public let mimeType: String

    public init(id: String, filename: String, byteCount: Int, mimeType: String) {
        self.id = id
        self.filename = filename
        self.byteCount = byteCount
        self.mimeType = mimeType
    }
}
