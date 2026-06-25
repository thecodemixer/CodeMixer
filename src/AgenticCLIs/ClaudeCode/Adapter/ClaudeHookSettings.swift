import Foundation
import AgentCore

/// Idempotent installer for `.claude/settings.local.json` hook entries that
/// forward Claude Code's lifecycle events to our Unix-domain socket.
///
/// We merge into the user's existing settings file rather than overwriting,
/// preserving any unrelated keys. Hooks we own are tagged with a
/// `codemixer.managed: true` marker so we can find and refresh them on launch.
public struct ClaudeHookInstaller: Sendable {

    public enum InstallError: Error, Sendable {
        case settingsWriteFailed(String)
    }

    private let fileSystem: any FileSystem

    public init(fileSystem: any FileSystem) {
        self.fileSystem = fileSystem
    }

    /// Returns the directory containing `settings.local.json` for `workspace`.
    public func settingsURL(for workspace: URL) -> URL {
        workspace.appendingPathComponent(".claude/settings.local.json")
    }

    /// Install hook entries pointing at `socketPath`, idempotently. Returns
    /// the URL that was written so callers can log it.
    @discardableResult
    public func install(socketPath: String, into workspace: URL) throws -> URL {
        let settingsURL = settingsURL(for: workspace)
        let parent = settingsURL.deletingLastPathComponent()
        try fileSystem.createDirectory(at: parent, withIntermediates: true)

        var json = readExisting(at: settingsURL)
        let existingHooks: [String: AnyCodableValue]
        if case .object(let hooks) = json["hooks"] {
            existingHooks = hooks
        } else {
            existingHooks = [:]
        }
        var hooks = existingHooks

        for event in Self.managedEvents {
            hooks[event] = mergedHookEntries(existing: hooks[event],
                                             socketPath: socketPath)
        }
        json["hooks"] = .object(hooks)

        let data: Data
        do {
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            data = try encoder.encode(json)
        } catch {
            throw InstallError.settingsWriteFailed(error.localizedDescription)
        }

        try fileSystem.writeAtomically(data, to: settingsURL)
        return settingsURL
    }

    // MARK: - Private

    private static let managedEvents = [
        "PreToolUse", "PostToolUse", "UserPromptSubmit", "Notification",
        "SessionStart", "Stop", "SubagentStop"
    ]

    private func readExisting(at url: URL) -> [String: AnyCodableValue] {
        guard fileSystem.fileExists(at: url),
              let data = try? fileSystem.readData(at: url),
              let dict = try? JSONDecoder().decode([String: AnyCodableValue].self, from: data) else {
            return [:]
        }
        return dict
    }

    private func mergedHookEntries(existing: AnyCodableValue?,
                                   socketPath: String) -> AnyCodableValue {
        var entries: [AnyCodableValue]
        switch existing {
        case .array(let values):
            entries = values
        case .object:
            entries = existing.map { [$0] } ?? []
        default:
            entries = []
        }
        entries.removeAll(where: isCodemixerOwnedHookEntry)
        entries.append(managedHookEntry(socketPath: socketPath))
        return .array(entries)
    }

    private func managedHookEntry(socketPath: String) -> AnyCodableValue {
        // Claude hook commands receive the JSON payload on stdin and expect any
        // hook response on stdout. A tiny Python shim gives us explicit
        // Unix-socket half-close semantics: send all stdin, shutdown writes so
        // HookServer observes EOF, then print the server's response.
        let script = """
        import socket, sys
        path = sys.argv[1]
        payload = sys.stdin.buffer.read()
        sock = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
        sock.connect(path)
        sock.sendall(payload)
        sock.shutdown(socket.SHUT_WR)
        chunks = []
        while True:
            chunk = sock.recv(65536)
            if not chunk:
                break
            chunks.append(chunk)
        sys.stdout.buffer.write(b"".join(chunks))
        """
        let command = "/usr/bin/python3 -c \(quotedShell(script)) \(quotedShell(socketPath))"
        return .object([
            "codemixer.managed": .bool(true),
            "matcher": .string("*"),
            "hooks": .array([
                .object([
                    "type": .string("command"),
                    "command": .string(command),
                ])
            ])
        ])
    }

    private func isCodemixerOwnedHookEntry(_ value: AnyCodableValue) -> Bool {
        if case .object(let object) = value,
           case .bool(true) = object["codemixer.managed"] {
            return true
        }
        return hookCommands(in: value).contains { command in
            command.contains("codemixer-spike-hook-") ||
            command.contains("codemixer.managed")
        }
    }

    private func hookCommands(in value: AnyCodableValue) -> [String] {
        switch value {
        case .string(let string):
            return [string]
        case .array(let values):
            return values.flatMap(hookCommands)
        case .object(let object):
            return object.values.flatMap(hookCommands)
        default:
            return []
        }
    }

    private func quotedShell(_ path: String) -> String {
        "'" + path.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }
}
