import Foundation

/// How a project chooses which agent CLI(s) drive chats — or which non-agent
/// folder browser surface to show.
///
/// This is a *project type* (Claude-only, Codex-only, Cursor-only, mixed,
/// custom, folder) — not an in-session agent mode. Agent modes (Cursor
/// agent/plan/ask, Claude Think/Review, …) come from
/// `AgentAdapter.availableAgentModes()`.
///
/// Required at project creation — there is no unset/nil type and no silent
/// default to Claude.
public enum ProjectType: Sendable, Codable, Hashable {
    case claudeCode
    case codex
    case cursorCLI
    case mixed(defaultAgent: AgentID?)
    case custom(CustomAgentRef)
    case folder(FolderProjectKind)

    /// Primary agent used for a new chat when the type does not require a
    /// fresh choice. Mixed types return their default (or nil). Custom
    /// returns `.other` because custom adapters are not in `AgentID.shipping`.
    /// Folder projects return `nil` — they are not agent-backed.
    ///
    /// Pinned built-ins resolve through `SupportedBuiltInAgent` so adding a
    /// shipping CLI does not require a third parallel switch here.
    public var primaryAgentID: AgentID? {
        switch self {
        case .mixed(let defaultAgent):
            return defaultAgent
        case .custom:
            return .other
        case .folder:
            return nil
        case .claudeCode, .codex, .cursorCLI:
            return SupportedBuiltInAgent.shipping.first { $0.projectType == self }?.id
        }
    }

    public var shortLabel: String {
        switch self {
        case .mixed:
            return "Mixed"
        case .custom(let ref):
            return ref.displayName
        case .folder(let kind):
            return kind.shortLabel
        case .claudeCode, .codex, .cursorCLI:
            return SupportedBuiltInAgent.shipping.first { $0.projectType == self }?.shortLabel
                ?? "Agent"
        }
    }

    /// True for projects that spawn / resume an agent CLI.
    public var isAgentBacked: Bool {
        switch self {
        case .folder: return false
        case .claudeCode, .codex, .cursorCLI, .mixed, .custom: return true
        }
    }

    /// True for projects that open a folder browser instead of a chat session.
    public var isFolderBacked: Bool {
        if case .folder = self { return true }
        return false
    }

    /// Folder kind when this is a folder project.
    public var folderKind: FolderProjectKind? {
        if case .folder(let kind) = self { return kind }
        return nil
    }

    /// Capsules beside the project title are reserved for single-agent built-ins.
    public var showsSidebarTypeCapsule: Bool {
        switch self {
        case .claudeCode, .codex, .cursorCLI: return true
        case .mixed, .custom, .folder: return false
        }
    }
}

/// Non-agent folder browser mode for `ProjectType.folder`.
public enum FolderProjectKind: String, Sendable, Codable, Hashable, CaseIterable, Identifiable {
    case files
    case logs
    case docs
    case modelhike

    public var id: String { rawValue }

    public var displayLabel: String {
        switch self {
        case .files: return "Files"
        case .logs: return "Logs"
        case .docs: return "Docs"
        case .modelhike: return "Modelhike"
        }
    }

    public var shortLabel: String { displayLabel }

    public var systemImage: String {
        switch self {
        case .files: return "folder"
        case .logs: return "doc.text"
        case .docs: return "book"
        case .modelhike: return "point.3.connected.trianglepath.dotted"
        }
    }

    /// Whether selecting a file opens a right-side preview.
    public var showsPreviewOnSelection: Bool {
        switch self {
        case .files: return false
        case .logs, .docs, .modelhike: return true
        }
    }

    /// Whether the preview surface is markdown HTML (vs plain text / none).
    public var usesMarkdownPreview: Bool {
        switch self {
        case .docs, .modelhike: return true
        case .files, .logs: return false
        }
    }

    /// User-pinned sidebar shortcuts are supported for these kinds.
    public var supportsPinnedSidebarEntries: Bool {
        switch self {
        case .files, .docs, .modelhike: return true
        case .logs: return false
        }
    }

    /// Automatic newest-file shortcuts (never persisted).
    public var showsAutomaticSidebarShortcuts: Bool {
        self == .logs
    }
}

/// User-defined agent configuration for a `ProjectType.custom` project.
public struct CustomAgentRef: Sendable, Codable, Hashable {
    public let id: String
    public let displayName: String
    public let transport: AgentTransportDescriptor
    public let executablePath: String
    public let arguments: [String]

    public init(id: String,
                displayName: String,
                transport: AgentTransportDescriptor,
                executablePath: String,
                arguments: [String]) {
        self.id = id
        self.displayName = displayName
        self.transport = transport
        self.executablePath = executablePath
        self.arguments = arguments
    }
}

/// Minimal folder-view state persisted beside `projectType` in
/// `<project>/.codemixer/project.json`. Browser preferences (search, sort,
/// scroll, follow) are intentionally *not* stored here.
public struct FolderViewState: Sendable, Codable, Hashable {
    /// Maximum pinned sidebar shortcuts for files / docs / modelhike.
    public static let maxPinnedPaths = 5

    /// Project-relative paths in user-defined order.
    public var pinnedRelativePaths: [String]

    public init(pinnedRelativePaths: [String] = []) {
        self.pinnedRelativePaths = pinnedRelativePaths
    }

    /// Keeps at most `maxPinnedPaths` unique relative paths, preserving order.
    public static func normalized(_ paths: [String]) -> [String] {
        var seen = Set<String>()
        var result: [String] = []
        for path in paths {
            let trimmed = path.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty, !trimmed.hasPrefix("/") else { continue }
            guard seen.insert(trimmed).inserted else { continue }
            result.append(trimmed)
            if result.count == maxPinnedPaths { break }
        }
        return result
    }
}

/// Named limits for folder browser scans and previews.
public enum FolderBrowserLimits {
    public static let maxScanEntries = 5_000
    public static let logPreviewTailBytes = 1_048_576
    public static let markdownPreviewMaxBytes = 2_097_152
    public static let automaticLogShortcuts = 5
    public static let scanDebounce: Duration = .milliseconds(250)
}

/// One sidebar shortcut under a folder project title.
public struct FolderSidebarShortcut: Sendable, Hashable, Identifiable {
    public var id: String { relativePath }
    public let relativePath: String
    public let displayName: String

    public init(relativePath: String, displayName: String? = nil) {
        self.relativePath = relativePath
        self.displayName = displayName ?? URL(fileURLWithPath: relativePath).lastPathComponent
    }
}
