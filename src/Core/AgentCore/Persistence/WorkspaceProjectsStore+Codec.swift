import Foundation

/// `workspaces.json` load / persist, including the legacy (pre-v2) schema's
/// tolerant decode. Schema versioning and the never-auto-migrate-to-Claude
/// invariant are documented on `WorkspaceProjectsStore.currentSchemaVersion`.
///
/// Load order is schema-first via `PersistenceJSON.schemaVersion(in:)` so a
/// v1 file that cannot decode as the current `Persisted`/`ProjectRef` shape
/// still reaches the loose legacy path instead of the whole-file quiet reset.
extension WorkspaceProjectsStore {
    public func load() async {
        decodeFailures = []
        do {
            try fileSystem.createDirectory(at: url.deletingLastPathComponent(),
                                           withIntermediates: true)
            guard fileSystem.fileExists(at: url) else { return }
            let data = try fileSystem.readData(at: url)
            let schemaVersion = try PersistenceJSON.schemaVersion(in: data)
            guard schemaVersion <= Self.currentSchemaVersion else {
                log.warning("""
                    workspaces.json schemaVersion \(schemaVersion, privacy: .public) \
                    is newer than \(Self.currentSchemaVersion, privacy: .public); ignoring to \
                    avoid corrupting a newer build's data.
                    """)
                await SilentDiagnostics.shared.record(kind: .workspacesSchemaTooNew,
                                                      owner: "WorkspaceProjectsStore",
                                                      summary: "workspaces.json schema too new; keeping in-memory model",
                                                      details: "schemaVersion=\(schemaVersion)")
                return
            }

            // Schema v1 used optional `agentID` instead of required `projectType`.
            // We do not migrate: decode each project strictly and surface failures.
            if schemaVersion < 2 {
                let failures = try decodeLegacyOrStrict(data: data)
                if !failures.isEmpty {
                    decodeFailures = failures
                    await SilentDiagnostics.shared.record(
                        kind: .other,
                        owner: "WorkspaceProjectsStore",
                        summary: "workspaces.json has undecodable projects; surfaced for repair",
                        details: failures.map { String(describing: $0) }.joined(separator: "; ")
                    )
                }
                return
            }

            let persisted = try PersistenceJSON.decode(Persisted.self, from: data)
            var merged: [String: [ProjectRef]] = [:]
            var duplicatePaths: [String] = []
            for entry in persisted.workspaces {
                if merged[entry.workspacePath] != nil {
                    duplicatePaths.append(entry.workspacePath)
                }
                merged[entry.workspacePath] = entry.projects
            }
            workspaces = merged
            activeWorkspacePath = persisted.activeWorkspacePath
            if !duplicatePaths.isEmpty {
                let paths = duplicatePaths.joined(separator: ", ")
                log.warning("workspaces.json duplicate workspacePath(s); last entry wins: \(paths, privacy: .public)")
                await SilentDiagnostics.shared.record(kind: .other,
                                                      owner: "WorkspaceProjectsStore",
                                                      summary: "duplicate workspacePath in workspaces.json; last entry wins",
                                                      details: paths)
            }
        } catch {
            // Whole-file failure: surface via diagnostics and keep empty model,
            // but do not invent project types for any recovered project.
            log.warning("workspaces load failed: \(String(describing: error), privacy: .public). Using empty model.")
            decodeFailures = [.undecodableProject(path: url.path, detail: String(describing: error))]
            await SilentDiagnostics.shared.record(kind: .workspacesQuietReset,
                                                  owner: "WorkspaceProjectsStore",
                                                  summary: "workspaces.json unreadable; using empty model",
                                                  details: String(describing: error))
        }
    }

    /// Non-private: called from the mutation and query paths in the other
    /// files in this directory.
    func persist() async throws {
        let entries = workspaces
            .map { WorkspaceEntry(workspacePath: $0.key, projects: $0.value) }
            .sorted { $0.workspacePath < $1.workspacePath }
        let persisted = Persisted(schemaVersion: Self.currentSchemaVersion,
                                  activeWorkspacePath: activeWorkspacePath,
                                  workspaces: entries)
        let data = try PersistenceJSON.encode(persisted)
        try fileSystem.writeAtomically(data, to: url)
    }

    /// Attempt a strict v2 decode of each project object. Legacy v1 entries
    /// without `projectType` become `undecodableProject` failures — never
    /// auto-migrated to Claude.
    private func decodeLegacyOrStrict(data: Data) throws -> [StoreError] {
        struct LoosePersisted: Decodable {
            var schemaVersion: Int
            var workspaces: [LooseWorkspace]
        }
        struct LooseWorkspace: Decodable {
            var workspacePath: String
            var projects: [LooseProject]
        }
        struct LooseProject: Decodable {
            var path: String
            var displayName: String
            var projectType: ProjectType?
            var agentID: AgentID?
        }

        let loose = try PersistenceJSON.decode(LoosePersisted.self, from: data)
        var failures: [StoreError] = []
        var merged: [String: [ProjectRef]] = [:]
        for entry in loose.workspaces {
            var refs: [ProjectRef] = []
            for project in entry.projects {
                if let mode = project.projectType {
                    refs.append(ProjectRef(path: project.path,
                                           displayName: project.displayName,
                                           projectType: mode))
                } else {
                    failures.append(.undecodableProject(
                        path: project.path,
                        detail: "missing required projectType (legacy agentID=\(project.agentID?.rawValue ?? "nil"))"
                    ))
                }
            }
            if !refs.isEmpty {
                merged[entry.workspacePath] = refs
            }
        }
        workspaces = merged
        return failures
    }
}
