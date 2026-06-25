import Foundation
import OSLog
import AgentProtocol

/// Persists `AppearancePrefs` and the auto-approval rules list to
/// `<appSupport>/prefs.json` atomically.
///
/// All disk IO goes through the `FileSystem` seam so tests can substitute
/// `InMemoryFileSystem`.
public actor PrefsStore {

    public struct State: Sendable, Codable, Hashable {
        public var appearance: AppearancePrefs
        public var autoApprovalRules: [AutoApprovalRule]

        public init(appearance: AppearancePrefs = .init(), autoApprovalRules: [AutoApprovalRule] = []) {
            self.appearance = appearance
            self.autoApprovalRules = autoApprovalRules
        }
    }

    private let log = Logger(subsystem: AppIdentity.logSubsystem, category: "PrefsStore")
    private let fileSystem: any FileSystem
    private let url: URL
    private var cached: State

    public init(environment: any AgentEnvironment, fileSystem: any FileSystem) {
        self.fileSystem = fileSystem
        self.url = AppSupportPaths.prefsURL(in: environment.appSupportDirectory)
        self.cached = State()
    }

    /// Read from disk into the in-memory cache. Idempotent.
    public func load() async {
        do {
            try fileSystem.createDirectory(at: url.deletingLastPathComponent(),
                                           withIntermediates: true)
            guard fileSystem.fileExists(at: url) else { return }
            let data = try fileSystem.readData(at: url)
            cached = try JSONDecoder().decode(State.self, from: data)
        } catch {
            log.warning("prefs load failed: \(String(describing: error), privacy: .public). Using defaults.")
        }
    }

    public func state() -> State { cached }

    public func updateAppearance(_ key: AppearancePrefKey, value: AppearancePrefValue) async throws {
        var next = cached
        next.appearance.update(key, value)
        try await persist(next)
    }

    public func updateRules(_ rules: [AutoApprovalRule]) async throws {
        var next = cached
        next.autoApprovalRules = rules
        try await persist(next)
    }

    public func matchingRule(toolName: String, summary: String) -> AutoApprovalRule? {
        let candidate = "\(toolName) \(summary)"
        return cached.autoApprovalRules.first { rule in
            rule.enabled && Self.matches(pattern: rule.match, in: candidate)
        }
    }

    // MARK: - Private

    private func persist(_ next: State) async throws {
        let data = try JSONEncoder.pretty.encode(next)
        try fileSystem.writeAtomically(data, to: url)
        cached = next
    }

    /// Glob-style match: `*` matches any run of characters; everything else
    /// is literal. Pre-compilation isn't worth the complexity at this scale.
    private static func matches(pattern: String, in input: String) -> Bool {
        let regexSafe = NSRegularExpression.escapedPattern(for: pattern)
            .replacingOccurrences(of: "\\*", with: ".*")
        guard let regex = try? NSRegularExpression(pattern: "^\(regexSafe)$",
                                                   options: [.caseInsensitive]) else {
            return false
        }
        let range = NSRange(input.startIndex..., in: input)
        return regex.firstMatch(in: input, range: range) != nil
    }
}

private extension JSONEncoder {
    static let pretty: JSONEncoder = {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        return encoder
    }()
}
