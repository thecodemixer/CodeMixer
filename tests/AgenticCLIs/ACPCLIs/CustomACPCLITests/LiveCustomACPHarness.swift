import Foundation
import ACPCLIs
import AgentClientProtocol
import AgentCore
import AgentProtocol

/// Opt-in driver for a real ACP binary through `CustomACPAdapter` (Codemixer path).
///
/// Gate: `CODEMIXER_LIVE_CUSTOM_ACP=1` and `CODEMIXER_LIVE_ACP_BIN=/path/to/agent`.
///
/// Multi-file migration reflection (dashboard + file sessions + dual-review → fixer):
///   CODEMIXER_LIVE_CUSTOM_ACP=1 \
///   CODEMIXER_LIVE_ACP_BIN=$PWD/migration-tool/dist/migration-acp \
///   CODEMIXER_LIVE_MIGRATION_PIPELINE=1 \
///   swift test --no-parallel --filter liveMigrationReflection
struct LiveCustomACPHarness {
    struct Configuration: Sendable {
        var workspace: URL
        var executablePath: String
        var arguments: [String]
        var prompt: String
        var expectedFinalSubstring: String
        var sessionReadyTimeout: Duration
        var assistantTextTimeout: Duration

        init(workspace: URL,
             executablePath: String,
             arguments: [String] = ["acp"],
             prompt: String = "Reply with exactly: codemixer-custom-acp-pong",
             expectedFinalSubstring: String = "codemixer-custom-acp-pong",
             sessionReadyTimeout: Duration = .seconds(90),
             assistantTextTimeout: Duration = .seconds(120)) {
            self.workspace = workspace
            self.executablePath = executablePath
            self.arguments = arguments
            self.prompt = prompt
            self.expectedFinalSubstring = expectedFinalSubstring
            self.sessionReadyTimeout = sessionReadyTimeout
            self.assistantTextTimeout = assistantTextTimeout
        }
    }

    struct Result: Sendable {
        let sessionID: String?
        let finalAssistantText: String?
        let modeIDs: [String]
    }

    struct MigrationReflectionConfiguration: Sendable {
        var workspace: URL
        var executablePath: String
        /// Args after the binary. Prefer `["acp", "--cwd", workspace.path]`.
        var arguments: [String]
        var reviewOptionID: String
        var minFileSessions: Int
        var pipelineTimeout: Duration
        var dashboardTimeout: Duration

        init(workspace: URL,
             executablePath: String,
             arguments: [String]? = nil,
             reviewOptionID: String = "accept_a",
             minFileSessions: Int = 2,
             pipelineTimeout: Duration = .seconds(2_400),
             dashboardTimeout: Duration = .seconds(60)) {
            self.workspace = workspace
            self.executablePath = executablePath
            self.arguments = arguments ?? ["acp", "--cwd", workspace.path]
            self.reviewOptionID = reviewOptionID
            self.minFileSessions = minFileSessions
            self.pipelineTimeout = pipelineTimeout
            self.dashboardTimeout = dashboardTimeout
        }
    }

    struct MigrationReflectionResult: Sendable {
        let dashboardURL: URL
        let dashboardTitle: String?
        let controlSessionID: String?
        let fileSessionIDs: [String]
        let sessionIndexChangedCount: Int
        let attentionRaisedCount: Int
        let attentionClearedCount: Int
        let permissionResolvedCount: Int
        let runState: String
        let verifiedFiles: [String]
        let filesMissingRoles: [String]
        let allRolesPresent: Bool
        let everyFileVerified: Bool
        let everyFileHadFixer: Bool
    }

    static let pipelineRoles = ["planner", "implementer", "reviewerA", "reviewerB", "fixer"]

    static func isEnabled() -> Bool {
        ProcessInfo.processInfo.environment["CODEMIXER_LIVE_CUSTOM_ACP"] == "1"
    }

    /// Full Codemixer-reflected live migration. Off unless explicitly opted in
    /// (`CODEMIXER_LIVE_MIGRATION_PIPELINE=1`) because it takes tens of minutes.
    static func isMigrationPipelineEnabled() -> Bool {
        isEnabled()
            && ProcessInfo.processInfo.environment["CODEMIXER_LIVE_MIGRATION_PIPELINE"] == "1"
    }

    static func executablePath() -> String? {
        let env = ProcessInfo.processInfo.environment
        let path = env["CODEMIXER_LIVE_ACP_BIN"] ?? env["CODEMIXER_CUSTOM_ACP_BIN"]
        guard let path, !path.isEmpty else { return nil }
        return path
    }

    func run(_ config: Configuration) async throws -> Result {
        let ref = CustomAgentRef(
            id: "live-custom",
            displayName: "Live Custom ACP",
            transport: .agentClientProtocol,
            executablePath: config.executablePath,
            arguments: config.arguments
        )
        let env = SystemEnvironment()
        let fs = SystemFileSystem()
        let adapter = CustomACPAdapter(
            ref: ref,
            environment: env,
            fileSystem: fs
        )
        let engine = AgentEngine(seams: Seams(
            clock: SystemClock(),
            random: SystemRandomSource(),
            environment: env,
            fileSystem: fs
        ))
        await engine.bootstrap()

        let sink = LiveCustomEventSink()
        let sub = await engine.bus.subscribe()
        let collector = Task { await sink.ingest(sub.stream) }
        defer {
            collector.cancel()
            Task {
                await engine.bus.unsubscribe(sub.id)
                await engine.shutdown(reason: .naturalExit)
            }
        }

        try await engine.start(adapter: adapter, workspace: config.workspace)
        let ready = await pollUntil(timeout: config.sessionReadyTimeout) {
            await sink.sessionID() != nil
        }
        guard ready else {
            throw LiveCustomACPError.timeout("sessionStarted")
        }

        let modeIDs = adapter.availableAgentModes().map(\.id)
        try await engine.send(.sendPrompt(text: config.prompt, attachments: []))
        let sawFinal = await pollUntil(timeout: config.assistantTextTimeout) {
            await sink.finalAssistantText()?.contains(config.expectedFinalSubstring) == true
        }
        guard sawFinal else {
            throw LiveCustomACPError.timeout("assistant final")
        }

        return Result(
            sessionID: await sink.sessionID(),
            finalAssistantText: await sink.finalAssistantText(),
            modeIDs: modeIDs
        )
    }

    /// Runs live `migration-acp` through Codemixer's Custom ACP adapter and asserts
    /// the same surfaces the GUI reduces: dashboard URL, reverse file sessions,
    /// attention badges, parked review permissions, and full per-file pipeline roles.
    func runMigrationReflection(_ config: MigrationReflectionConfiguration) async throws
        -> MigrationReflectionResult {
        try Self.seedMigrationWorkspace(at: config.workspace, executablePath: config.executablePath)

        let ref = CustomAgentRef(
            id: "live-migration",
            displayName: "Migration Tool",
            transport: .agentClientProtocol,
            executablePath: config.executablePath,
            arguments: config.arguments
        )
        let env = SystemEnvironment()
        let fs = SystemFileSystem()
        let adapter = CustomACPAdapter(ref: ref, environment: env, fileSystem: fs)
        let engine = AgentEngine(seams: Seams(
            clock: SystemClock(),
            random: SystemRandomSource(),
            environment: env,
            fileSystem: fs
        ))
        await engine.bootstrap()

        let sink = LiveCustomEventSink()
        let sub = await engine.bus.subscribe()
        let collector = Task { await sink.ingest(sub.stream) }
        let permissionLoop = Task {
            var responded = Set<UUID>()
            var loadedAttention = Set<String>()
            var dashboardResolved = Set<String>()
            while !Task.isCancelled {
                // Codemixer UI path: focus a file session with attention so parked
                // review re-emits as permissionRequest, then select accept_a.
                for sessionID in await sink.sessionsNeedingAttention() where !loadedAttention.contains(sessionID) {
                    loadedAttention.insert(sessionID)
                    try? await engine.send(.openProject(
                        path: config.workspace.path,
                        resumeSessionID: sessionID
                    ))
                }
                if let pending = await sink.pendingPermission(excluding: responded) {
                    responded.insert(pending.id)
                    let decision: PermissionDecision =
                        pending.options?.contains(where: { $0.optionId == config.reviewOptionID }) == true
                        ? .option(id: config.reviewOptionID)
                        : .allow
                    try? await engine.send(.respondToPermission(id: pending.id, decision: decision))
                }

                // Dashboard path (same as SPA Review Queue): first-wins with chat.
                if let dash = await sink.dashboardURL(),
                   let state = try? await Self.fetchJSON(url: dash.appending(path: "api/state")),
                   let files = state["files"] as? [String: Any] {
                    for (path, value) in files {
                        guard let rec = value as? [String: Any],
                              (rec["status"] as? String) == "needs-human-review",
                              !dashboardResolved.contains(path)
                        else { continue }
                        dashboardResolved.insert(path)
                        let url = try Self.needsReviewURL(dashboard: dash, filePath: path)
                        try? await Self.postJSON(url: url, body: ["optionId": config.reviewOptionID])
                    }
                }
                try? await Task.sleep(for: .milliseconds(250))
            }
            return responded.count
        }
        defer {
            permissionLoop.cancel()
            collector.cancel()
            Task {
                await engine.bus.unsubscribe(sub.id)
                await engine.shutdown(reason: .naturalExit)
            }
        }

        try await engine.start(adapter: adapter, workspace: config.workspace)

        let dashboardReady = await pollUntil(timeout: config.dashboardTimeout) {
            let hasDashboard = await sink.dashboardURL() != nil
            let hasSession = await sink.sessionID() != nil
            return hasDashboard && hasSession
        }
        guard dashboardReady, let dashboardURL = await sink.dashboardURL() else {
            throw LiveCustomACPError.timeout("agentDashboard + control session")
        }

        try await Self.postEmpty(url: dashboardURL.appending(path: "api/run/start"))

        let pipelineDone = await pollUntil(timeout: config.pipelineTimeout) {
            let state = try? await Self.fetchJSON(url: dashboardURL.appending(path: "api/state"))
            let runState = state?["runState"] as? String
            guard runState == "complete" || runState == "paused-error" else { return false }
            let files = state?["files"] as? [String: Any] ?? [:]
            let verified = files.values.compactMap { value -> String? in
                guard let rec = value as? [String: Any],
                      let status = rec["status"] as? String,
                      status == "verified" || status == "needs-human-review" || status == "approved"
                else { return nil }
                return status
            }
            return verified.count >= config.minFileSessions
        }
        guard pipelineDone else {
            throw LiveCustomACPError.timeout("migration run complete with file sessions")
        }

        // Drain any last parked reviews after the run parks on needs-human-review.
        _ = await pollUntil(timeout: .seconds(180)) {
            let state = try? await Self.fetchJSON(url: dashboardURL.appending(path: "api/state"))
            let runState = state?["runState"] as? String
            let files = state?["files"] as? [String: Any] ?? [:]
            let pending = files.values.contains { value in
                guard let rec = value as? [String: Any] else { return false }
                return (rec["status"] as? String) == "needs-human-review"
            }
            return runState == "complete" && !pending
        }

        permissionLoop.cancel()
        let permissionResolvedCount = (try? await permissionLoop.value) ?? 0

        let evidence = try Self.readPipelineEvidence(projectRoot: config.workspace)
        let fileSessionIDs = Self.fileSessionIDsFromStore(
            projectRoot: config.workspace,
            customAgentID: ref.id
        )
        let result = MigrationReflectionResult(
            dashboardURL: dashboardURL,
            dashboardTitle: await sink.dashboardTitle(),
            controlSessionID: await sink.sessionID(),
            fileSessionIDs: fileSessionIDs,
            sessionIndexChangedCount: await sink.sessionIndexChangedCount(),
            attentionRaisedCount: await sink.attentionRaisedCount(),
            attentionClearedCount: await sink.attentionClearedCount(),
            permissionResolvedCount: permissionResolvedCount,
            runState: evidence.runState,
            verifiedFiles: evidence.verifiedFiles,
            filesMissingRoles: evidence.filesMissingRoles,
            allRolesPresent: evidence.allRolesPresent,
            everyFileVerified: evidence.everyFileVerified,
            everyFileHadFixer: evidence.everyFileHadFixer
        )

        guard await sink.dashboardURL() != nil else {
            throw LiveCustomACPError.assertion("Codemixer never received agentDashboard")
        }
        guard result.fileSessionIDs.count >= config.minFileSessions else {
            throw LiveCustomACPError.assertion(
                "expected ≥\(config.minFileSessions) reverse file sessions in ACP session index; got \(result.fileSessionIDs)"
            )
        }
        guard result.sessionIndexChangedCount > 0 else {
            throw LiveCustomACPError.assertion("Codemixer never received sessionIndexChanged")
        }
        guard result.attentionRaisedCount > 0 || permissionResolvedCount > 0 else {
            throw LiveCustomACPError.assertion(
                "Codemixer saw neither sessionAttentionChanged(true) nor a review permission resolve"
            )
        }
        guard result.allRolesPresent, result.everyFileVerified, result.everyFileHadFixer else {
            throw LiveCustomACPError.assertion(
                "pipeline incomplete missing=\(result.filesMissingRoles) verified=\(result.verifiedFiles)"
            )
        }
        return result
    }

    // MARK: - Workspace seed

    static func seedMigrationWorkspace(at root: URL, executablePath: String) throws {
        let fm = FileManager.default
        if fm.fileExists(atPath: root.path) {
            try fm.removeItem(at: root)
        }
        try fm.createDirectory(at: root, withIntermediateDirectories: true)

        let sources: [(String, String)] = [
            (
                "Controllers/CustomersController.cs",
                """
                using Microsoft.AspNetCore.Mvc;
                using Demo.Repositories;

                namespace Demo.Controllers;

                [ApiController]
                [Route("api/customers")]
                public class CustomersController : ControllerBase
                {
                  private readonly CustomersRepository _repo;
                  public CustomersController(CustomersRepository repo) => _repo = repo;

                  [HttpGet("{id:int}")]
                  public IActionResult Get(int id)
                  {
                    var row = _repo.GetById(id);
                    if (row is null) return NotFound();
                    return Ok(row);
                  }
                }
                """
            ),
            (
                "Repositories/CustomersRepository.cs",
                """
                using System.Data.SqlClient;

                namespace Demo.Repositories;

                public class CustomersRepository
                {
                  private readonly string _cs = "Server=.;Database=Demo;Trusted_Connection=True;";

                  public object? GetById(int id)
                  {
                    using var conn = new SqlConnection(_cs);
                    conn.Open();
                    using var cmd = new SqlCommand("SELECT Id, Name FROM Customers WHERE Id = @id", conn);
                    cmd.Parameters.AddWithValue("@id", id);
                    using var reader = cmd.ExecuteReader();
                    if (!reader.Read()) return null;
                    return new { Id = reader.GetInt32(0), Name = reader.GetString(1) };
                  }
                }
                """
            ),
        ]

        for (rel, body) in sources {
            let url = root.appendingPathComponent(rel)
            try fm.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try body.write(to: url, atomically: true, encoding: .utf8)
        }

        let config: [String: Any] = [
            "preset": "sqlserver-to-mongodb",
            "sourceDir": ".",
            "globs": sources.map(\.0),
            "ignoreGlobs": ["**/.git/**", "**/migrated/**", "**/.codemixer/**"],
            "concurrency": 1,
            "dryRun": false,
            "sideBySide": true,
            "maxFixRounds": 1,
            "verification": ["perFile": [String](), "wave": [String](), "mongoSmoke": [String]()],
            "models": [
                "planner": "composer-2.5",
                "implementer": "composer-2.5",
                "reviewerA": "composer-2.5",
                "reviewerB": "composer-2.5",
                "fixer": "composer-2.5",
            ],
            "features": [
                "assessment": true,
                "characterization": false,
                "sweeps": ["harmonizer": false, "security": false, "docs": false],
                "scheduling": "file-order",
            ],
        ]
        let configData = try JSONSerialization.data(withJSONObject: config, options: [.prettyPrinted, .sortedKeys])
        try configData.write(to: root.appendingPathComponent("migration.config.json"))

        // Codemixer project registration so a GUI open can attach the same Custom ACP agent.
        // Keep the CustomAgentRef.id stable so ACP session index under
        // `.codemixer/acp/<id>/` matches what AgentEngine used during the live run.
        let agentID = "live-migration"
        let ref = CustomAgentRef(
            id: agentID,
            displayName: "Migration Tool",
            transport: .agentClientProtocol,
            executablePath: executablePath,
            arguments: ["acp", "--cwd", root.path]
        )
        let projectRef = WorkspaceProjectsStore.ProjectRef(
            path: root.path,
            displayName: root.lastPathComponent,
            projectType: .custom(ref)
        )
        try ProjectLocalStateStore.save(ref: projectRef, fileSystem: SystemFileSystem())

        try runGit(["init"], cwd: root)
        try runGit(["add", "-A"], cwd: root)
        try runGit(
            ["-c", "user.email=live@codemixer.local", "-c", "user.name=LiveHarness", "commit", "-m", "seed"],
            cwd: root
        )
    }

    private static func fileSessionIDsFromStore(projectRoot: URL, customAgentID: String) -> [String] {
        // Codemixer reflects reverse session/new via ACPSessionIndex + sessionIndexChanged,
        // not a fresh sessionStarted event (control session already owns the engine session).
        let indexURL = projectRoot
            .appendingPathComponent(".codemixer/acp/\(customAgentID)/sessions-index.json")
        guard let data = try? Data(contentsOf: indexURL),
              let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let entries = root["entries"] as? [[String: Any]]
        else { return [] }
        return entries.compactMap { entry in
            guard let id = entry["id"] as? String, id.hasPrefix("file:") else { return nil }
            return id
        }.sorted()
    }

    private static func runGit(_ args: [String], cwd: URL) throws {
        let proc = Process()
        proc.executableURL = SystemPaths.git
        proc.arguments = args
        proc.currentDirectoryURL = cwd
        let err = Pipe()
        proc.standardError = err
        proc.standardOutput = Pipe()
        try proc.run()
        proc.waitUntilExit()
        guard proc.terminationStatus == 0 else {
            let msg = String(data: err.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
            throw LiveCustomACPError.assertion("git \(args.joined(separator: " ")) failed: \(msg)")
        }
    }

    private static func needsReviewURL(dashboard: URL, filePath: String) throws -> URL {
        var allowed = CharacterSet.urlPathAllowed
        allowed.remove(charactersIn: "/")
        let encoded = filePath.addingPercentEncoding(withAllowedCharacters: allowed) ?? filePath
        let base = dashboard.absoluteString.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        guard let url = URL(string: "\(base)/api/files/\(encoded)/needs-review") else {
            throw LiveCustomACPError.assertion("Could not build needs-review URL for \(filePath)")
        }
        return url
    }

    private static func postEmpty(url: URL) async throws {
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        let (_, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse, (200 ... 299).contains(http.statusCode) else {
            throw LiveCustomACPError.assertion("POST \(url.path) failed")
        }
    }

    private static func postJSON(url: URL, body: [String: String]) async throws {
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "content-type")
        request.httpBody = try JSONSerialization.data(withJSONObject: body)
        let (_, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse, (200 ... 299).contains(http.statusCode) else {
            throw LiveCustomACPError.assertion("POST \(url.path) failed")
        }
    }

    private static func fetchJSON(url: URL) async throws -> [String: Any] {
        let (data, response) = try await URLSession.shared.data(from: url)
        guard let http = response as? HTTPURLResponse, (200 ... 299).contains(http.statusCode) else {
            throw LiveCustomACPError.assertion("GET \(url.path) failed")
        }
        let obj = try JSONSerialization.jsonObject(with: data)
        guard let dict = obj as? [String: Any] else {
            throw LiveCustomACPError.assertion("GET \(url.path) returned non-object JSON")
        }
        return dict
    }

    private struct PipelineEvidence {
        var runState: String
        var verifiedFiles: [String]
        var filesMissingRoles: [String]
        var allRolesPresent: Bool
        var everyFileVerified: Bool
        var everyFileHadFixer: Bool
    }

    private static func readPipelineEvidence(projectRoot: URL) throws -> PipelineEvidence {
        let manifestURL = projectRoot
            .appendingPathComponent(".codemixer/migration/manifest.json")
        let data = try Data(contentsOf: manifestURL)
        let root = try JSONSerialization.jsonObject(with: data) as? [String: Any] ?? [:]
        let runState = root["runState"] as? String ?? "unknown"
        let files = root["files"] as? [String: Any] ?? [:]

        var verified: [String] = []
        var missing: [String] = []
        var allRoles = true
        var allVerified = files.count >= 2
        var allFixer = files.count >= 2

        for (path, value) in files {
            guard let rec = value as? [String: Any] else { continue }
            let status = rec["status"] as? String ?? "unknown"
            let fixRounds = rec["fixRounds"] as? Int ?? 0
            let agentIds = rec["agentIds"] as? [String: Any] ?? [:]
            let absent = pipelineRoles.filter { agentIds[$0] == nil }
            if !absent.isEmpty {
                allRoles = false
                missing.append("\(path):\(absent.joined(separator: ","))")
            }
            if status == "verified" {
                verified.append(path)
            } else {
                allVerified = false
            }
            if fixRounds < 1 || agentIds["fixer"] == nil {
                allFixer = false
            }
        }

        return PipelineEvidence(
            runState: runState,
            verifiedFiles: verified.sorted(),
            filesMissingRoles: missing.sorted(),
            allRolesPresent: allRoles && files.count >= 2,
            everyFileVerified: allVerified,
            everyFileHadFixer: allFixer
        )
    }
}

enum LiveCustomACPError: Error, CustomStringConvertible {
    case timeout(String)
    case assertion(String)

    var description: String {
        switch self {
        case .timeout(let label): "Timed out waiting for \(label)"
        case .assertion(let message): message
        }
    }
}

private actor LiveCustomEventSink {
    private var events: [AgentEvent] = []

    func ingest(_ stream: AsyncStream<MulticastEventBus.HistoryEntry>) async {
        for await entry in stream {
            events.append(entry.event)
            if events.count > 4_096 { events.removeFirst(events.count - 4_096) }
        }
    }

    func sessionID() -> String? {
        for event in events.reversed() {
            if case .sessionStarted(let id, _, _) = event, !id.isEmpty, !id.hasPrefix("file:") {
                return id
            }
        }
        // Fall back to any sessionStarted (control may also be titled differently).
        for event in events.reversed() {
            if case .sessionStarted(let id, _, _) = event, !id.isEmpty {
                return id
            }
        }
        return nil
    }

    func fileSessionIDs() -> [String] {
        var ids = Set<String>()
        for event in events {
            if case .sessionStarted(let id, _, _) = event, id.hasPrefix("file:") {
                ids.insert(id)
            }
        }
        return ids.sorted()
    }

    func dashboardURL() -> URL? {
        for event in events.reversed() {
            if case .agentDashboard(let url, _) = event {
                return url
            }
        }
        return nil
    }

    func dashboardTitle() -> String? {
        for event in events.reversed() {
            if case .agentDashboard(_, let title) = event {
                return title
            }
        }
        return nil
    }

    func sessionIndexChangedCount() -> Int {
        events.reduce(0) { count, event in
            if case .sessionIndexChanged = event { return count + 1 }
            return count
        }
    }

    func attentionRaisedCount() -> Int {
        events.reduce(0) { count, event in
            if case .sessionAttentionChanged(_, _, true) = event { return count + 1 }
            return count
        }
    }

    func attentionClearedCount() -> Int {
        events.reduce(0) { count, event in
            if case .sessionAttentionChanged(_, _, false) = event { return count + 1 }
            return count
        }
    }

    func sessionsNeedingAttention() -> [String] {
        var latest: [String: Bool] = [:]
        for event in events {
            if case .sessionAttentionChanged(let id, _, let needs) = event {
                latest[id] = needs
            }
        }
        return latest.compactMap { id, needs in needs ? id : nil }.sorted()
    }

    func pendingPermission(excluding responded: Set<UUID>) -> PermissionPrompt? {
        for event in events {
            if case .permissionRequest(let prompt) = event, !responded.contains(prompt.id) {
                return prompt
            }
        }
        return nil
    }

    func finalAssistantText() -> String? {
        for event in events.reversed() {
            if case .assistantText(_, _, let text, let isFinal) = event, isFinal {
                return text
            }
        }
        return nil
    }
}

private func pollUntil(timeout: Duration, _ condition: @escaping @Sendable () async -> Bool) async -> Bool {
    let deadline = ContinuousClock.now + timeout
    while ContinuousClock.now < deadline {
        if await condition() { return true }
        try? await Task.sleep(for: .milliseconds(100))
    }
    return await condition()
}
