import Foundation

/// User input variants accepted by `turn/start`.
///
/// The tagged cases mirror Codex App Server's wire names exactly. Skills and
/// mentions carry both a display name and an absolute source path.
public enum CodexUserInput: Sendable, Hashable, Codable {
    case text(String)
    case image(URL)
    case localImage(URL)
    case skill(name: String, path: URL)
    case mention(name: String, path: URL)

    private enum CodingKeys: String, CodingKey {
        case type
        case text
        case url
        case path
        case name
    }

    private enum Kind: String, Codable {
        case text
        case image
        case localImage
        case skill
        case mention
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        switch try container.decode(Kind.self, forKey: .type) {
        case .text:
            self = .text(try container.decode(String.self, forKey: .text))
        case .image:
            self = .image(try container.decode(URL.self, forKey: .url))
        case .localImage:
            self = .localImage(URL(fileURLWithPath: try container.decode(String.self, forKey: .path)))
        case .skill:
            self = .skill(
                name: try container.decode(String.self, forKey: .name),
                path: URL(fileURLWithPath: try container.decode(String.self, forKey: .path))
            )
        case .mention:
            self = .mention(
                name: try container.decode(String.self, forKey: .name),
                path: URL(fileURLWithPath: try container.decode(String.self, forKey: .path))
            )
        }
    }

    public func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        switch self {
        case .text(let text):
            try container.encode(Kind.text, forKey: .type)
            try container.encode(text, forKey: .text)
        case .image(let url):
            try container.encode(Kind.image, forKey: .type)
            try container.encode(url, forKey: .url)
        case .localImage(let path):
            try container.encode(Kind.localImage, forKey: .type)
            try container.encode(path.path, forKey: .path)
        case .skill(let name, let path):
            try container.encode(Kind.skill, forKey: .type)
            try container.encode(name, forKey: .name)
            try container.encode(path.path, forKey: .path)
        case .mention(let name, let path):
            try container.encode(Kind.mention, forKey: .type)
            try container.encode(name, forKey: .name)
            try container.encode(path.path, forKey: .path)
        }
    }

    var jsonValue: JSONValue {
        switch self {
        case .text(let text):
            return .object(["type": .string("text"), "text": .string(text)])
        case .image(let url):
            return .object(["type": .string("image"), "url": .string(url.absoluteString)])
        case .localImage(let path):
            return .object(["type": .string("localImage"), "path": .string(path.path)])
        case .skill(let name, let path):
            return .object([
                "type": .string("skill"),
                "name": .string(name),
                "path": .string(path.path),
            ])
        case .mention(let name, let path):
            return .object([
                "type": .string("mention"),
                "name": .string(name),
                "path": .string(path.path),
            ])
        }
    }
}

/// Codex thread-level sandbox modes.
public enum CodexSandboxMode: String, Sendable, Hashable, Codable {
    case readOnly = "read-only"
    case workspaceWrite = "workspace-write"
    case dangerFullAccess = "danger-full-access"
}

/// Codex thread-level approval policies.
public enum CodexApprovalPolicy: String, Sendable, Hashable, Codable {
    case untrusted
    case onRequest = "on-request"
    case never
}
