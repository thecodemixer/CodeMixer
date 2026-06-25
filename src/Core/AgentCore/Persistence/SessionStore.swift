import Foundation
import OSLog

/// Recent-projects + per-project metadata cache.
///
/// Persisted at `<appSupport>/sessions.json` as a small list of project
/// records, most-recently-opened first. Bounded to 32 entries.
public actor SessionStore {

    public struct ProjectRecord: Sendable, Codable, Hashable, Identifiable {
        public var id: String { path }
        public let path: String
        public var displayName: String
        public var lastOpened: Date
        public var lastSessionID: String?

        public init(path: String, displayName: String, lastOpened: Date, lastSessionID: String? = nil) {
            self.path = path
            self.displayName = displayName
            self.lastOpened = lastOpened
            self.lastSessionID = lastSessionID
        }
    }

    public struct State: Sendable, Codable, Hashable {
        public var projects: [ProjectRecord]
        public init(projects: [ProjectRecord] = []) { self.projects = projects }
    }

    private let log = Logger(subsystem: AppIdentity.logSubsystem, category: "SessionStore")
    private let fileSystem: any FileSystem
    private let url: URL
    private var cached: State
    private let limit: Int

    public init(environment: any AgentEnvironment,
                fileSystem: any FileSystem,
                limit: Int = 32) {
        self.fileSystem = fileSystem
        self.url = AppSupportPaths.sessionsURL(in: environment.appSupportDirectory)
        self.limit = limit
        self.cached = State()
    }

    public func load() async {
        do {
            try fileSystem.createDirectory(at: url.deletingLastPathComponent(),
                                           withIntermediates: true)
            guard fileSystem.fileExists(at: url) else { return }
            let data = try fileSystem.readData(at: url)
            let decoder = JSONDecoder()
            decoder.dateDecodingStrategy = .iso8601
            let decoded = try decoder.decode(State.self, from: data)
            cached = State(projects: decoded.projects.filter { Self.isPersistableWorkspacePath($0.path) })
        } catch {
            log.warning("sessions load failed: \(String(describing: error), privacy: .public). Using empty list.")
        }
    }

    public func recents() -> [ProjectRecord] { cached.projects }

    public func recordOpen(path: String,
                           displayName: String,
                           clock: any AgentClock,
                           sessionID: String? = nil) async throws {
        guard Self.isPersistableWorkspacePath(path) else { return }
        var list = cached.projects.filter { $0.path != path }
        list.insert(ProjectRecord(path: path,
                                  displayName: displayName,
                                  lastOpened: clock.now(),
                                  lastSessionID: sessionID),
                    at: 0)
        if list.count > limit { list = Array(list.prefix(limit)) }
        cached = State(projects: list)
        try await persist()
    }

    public func remove(path: String) async throws {
        cached = State(projects: cached.projects.filter { $0.path != path })
        try await persist()
    }

    // MARK: - Private

    private static func isPersistableWorkspacePath(_ path: String) -> Bool {
        !path.contains("/codemixer-twin-")
    }

    private func persist() async throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        let data = try encoder.encode(cached)
        try fileSystem.writeAtomically(data, to: url)
    }
}
