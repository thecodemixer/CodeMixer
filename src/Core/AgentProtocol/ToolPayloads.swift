import Foundation
import CryptoKit

/// Builds deterministic UUIDs from stable string material.
public enum StableID {
    public static func uuid(from material: String) -> UUID {
        let digest = Array(SHA256.hash(data: Data(material.utf8)))
        return UUID(uuid: (
            digest[0], digest[1], digest[2], digest[3],
            digest[4], digest[5], digest[6], digest[7],
            digest[8], digest[9], digest[10], digest[11],
            digest[12], digest[13], digest[14], digest[15]
        ))
    }
}

// MARK: - Shared tool / permission payloads

/// Contract for a tool-input payload shared by domain events and the wire
/// mirror. One concrete `ToolInput` conforms; there is no parallel wire DTO.
public protocol ToolInputPayload: Sendable {
    var summary: String { get }
    var jsonPayload: String? { get }
}

/// Compact, structured description of a tool's input. Used both in-process
/// (`AgentEvent`) and on the wire (`AgentEventWire`) — the fields are already
/// portable (no `URL` / `Duration`), so a second identical struct would only
/// duplicate the type.
public struct ToolInput: ToolInputPayload, Sendable, Codable, Hashable {
    public var summary: String
    public var jsonPayload: String?

    public init(summary: String, jsonPayload: String? = nil) {
        self.summary = summary
        self.jsonPayload = jsonPayload
    }
}

/// Contract for a tool-output payload shared by domain and wire.
public protocol ToolOutputPayload: Sendable {
    var summary: String { get }
    var jsonPayload: String? { get }
    var errorMessage: String? { get }
}

public struct ToolOutput: ToolOutputPayload, Sendable, Codable, Hashable {
    public var summary: String
    public var jsonPayload: String?
    public var errorMessage: String?

    public init(summary: String, jsonPayload: String? = nil, errorMessage: String? = nil) {
        self.summary = summary
        self.jsonPayload = jsonPayload
        self.errorMessage = errorMessage
    }
}

/// Live progress for a running tool call. Typed so each renderer reaches for
/// exactly the data it needs. Shared by domain and wire (already portable).
public enum ToolProgress: Sendable, Codable, Hashable {
    case bashLine(String)
    case fileBytes(written: Int, total: Int?)
    case generic(message: String)
}

/// Contract for a custom permission option shared by domain and wire.
public protocol PermissionOptionPayload: Sendable, Identifiable {
    var optionId: String { get }
    var label: String { get }
}

/// Custom permission option surfaced by ACP agents with non-standard choices.
public struct PermissionOption: PermissionOptionPayload, Sendable, Codable, Hashable, Identifiable {
    public let optionId: String
    public let label: String

    public var id: String { optionId }

    public init(optionId: String, label: String) {
        self.optionId = optionId
        self.label = label
    }
}

/// Contract for a permission prompt shared by domain and wire.
public protocol PermissionPromptPayload: Sendable, Identifiable {
    var id: UUID { get }
    var toolName: String { get }
    var summary: String { get }
    var argumentsSummary: String { get }
    var requestedAt: Date { get }
    var options: [PermissionOption]? { get }
}

/// Permission prompt the agent surfaced before executing a tool. Shared by
/// domain and wire — fields are already Codable-portable.
public struct PermissionPrompt: PermissionPromptPayload, Sendable, Codable, Hashable, Identifiable {
    public let id: UUID
    public let toolName: String
    public let summary: String
    public let argumentsSummary: String
    public let requestedAt: Date
    public let options: [PermissionOption]?

    public init(id: UUID,
                toolName: String,
                summary: String,
                argumentsSummary: String,
                requestedAt: Date,
                options: [PermissionOption]? = nil) {
        self.id = id
        self.toolName = toolName
        self.summary = summary
        self.argumentsSummary = argumentsSummary
        self.requestedAt = requestedAt
        self.options = options
    }

    public init(toolName: String,
                summary: String,
                argumentsSummary: String,
                requestedAt: Date,
                options: [PermissionOption]? = nil) {
        self.init(id: PermissionPrompt.stableID(
            toolName: toolName,
            summary: summary,
            argumentsSummary: argumentsSummary,
            requestedAt: requestedAt
        ),
        toolName: toolName,
        summary: summary,
        argumentsSummary: argumentsSummary,
        requestedAt: requestedAt,
        options: options)
    }

    private static func stableID(toolName: String,
                                 summary: String,
                                 argumentsSummary: String,
                                 requestedAt: Date) -> UUID {
        let material = "\(toolName)|\(summary)|\(argumentsSummary)|\(requestedAt.timeIntervalSince1970)"
        return StableID.uuid(from: material)
    }
}
