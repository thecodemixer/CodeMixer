import Foundation
import ClaudeCode

/// PTY-aware executable twin runtime.
struct FakeClaudeRuntime {
    let workspace: URL
    let claudeDirectory: URL
    let sessionID: String
    let scenario: ClaudeCodeTwinScenario
    let model: String
    let permissionMode: String
    let resumeSessionID: String?
    let hookRunner: HookCommandRunner

    init(workspace: URL,
         claudeDirectory: URL,
         sessionID: String,
         scenario: ClaudeCodeTwinScenario,
         model: String,
         permissionMode: String,
         resumeSessionID: String?) {
        self.workspace = workspace
        self.claudeDirectory = claudeDirectory
        self.sessionID = sessionID
        self.scenario = scenario
        self.model = model
        self.permissionMode = permissionMode
        self.resumeSessionID = resumeSessionID
        self.hookRunner = HookCommandRunner(workspace: workspace)
    }

    func runInteractive() {
        write(ClaudeCodeTwinPTYScript.banner(sessionID: sessionID) + "\n")

        var context = ClaudeCodeTwinScenarioRuntime.Context(
            sessionID: sessionID,
            workspace: workspace,
            claudeDirectory: claudeDirectory,
            model: model,
            permissionMode: permissionMode,
            resumeSessionID: resumeSessionID
        )

        let hookSink = ClaudeCodeTwinScenarioRuntime.HookSink.runner { eventName, payload in
            hookRunner.emit(eventName: eventName, payload: payload)
        }

        ClaudeCodeTwinScenarioRuntime.emitSessionStart(context: context, hookSink: hookSink)

        switch scenario {
        case .needsAuth(let url):
            write("Visit \(url.absoluteString) to authenticate\n")
        case .workspaceTrust(let path):
            write(ClaudeCodeTwinPTYScript.workspaceTrust(workspace: path))
        case .resumeLatePrompt, .resumeStalled:
            write(ClaudeCodeTwinPTYScript.statusWorking)
            if case .resumeLatePrompt = scenario {
                write(ClaudeCodeTwinPTYScript.startupPromptReady)
            }
        default:
            write(ClaudeCodeTwinPTYScript.startupPromptReady)
        }

        while true {
            guard let input = PTYInputReader.readNext() else { continue }
            switch input {
            case .eof:
                return
            case .interrupt:
                write("(interrupted)\n" + ClaudeCodeTwinPTYScript.promptReady)
            case .permissionChoice:
                write(ClaudeCodeTwinPTYScript.promptReady)
            case .submit(let text):
                let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
                if trimmed.isEmpty { continue }
                if trimmed == "/quit" || trimmed == "/exit" {
                    write("Goodbye.\n")
                    return
                }
                _ = try? ClaudeCodeTwinScenarioRuntime.execute(
                    scenario: scenario,
                    userPrompt: trimmed,
                    context: &context,
                    hookSink: hookSink,
                    writePTY: write
                )
            }
        }
    }

    private func write(_ text: String) {
        let terminalText = text.replacingOccurrences(of: "\n", with: "\r\n")
        FileHandle.standardOutput.write(Data(terminalText.utf8))
    }
}

enum FakeClaudeLaunch {
    static func claudeDirectory() -> URL {
        let home = ProcessInfo.processInfo.environment["HOME"]
            ?? FileManager.default.homeDirectoryForCurrentUser.path
        return URL(fileURLWithPath: home).appendingPathComponent(".claude", isDirectory: true)
    }

    static func resolveScenario() -> ClaudeCodeTwinScenario {
        if let file = ProcessInfo.processInfo.environment["CODEMIXER_TWIN_SCENARIO_FILE"],
           let data = try? Data(contentsOf: URL(fileURLWithPath: file)),
           let manifest = try? JSONDecoder().decode(ClaudeCodeTwinScenarioManifest.self, from: data),
           let turn = manifest.turns.first,
           let scenario = manifest.scenario(for: turn) {
            return scenario
        }
        if let name = ProcessInfo.processInfo.environment["CODEMIXER_TWIN_SCENARIO"],
           let scenario = ClaudeCodeTwinScenario.named(name) {
            return scenario
        }
        for arg in CommandLine.arguments {
            if arg.hasPrefix("--scenario="),
               let scenario = ClaudeCodeTwinScenario.named(String(arg.dropFirst("--scenario=".count))) {
                return scenario
            }
        }
        return .textOnly(reply: "Hello from fake-claude.")
    }

    static func parseInteractiveArgs() -> (permissionMode: String, resumeSessionID: String?, model: String) {
        var permissionMode = "default"
        var resumeSessionID: String?
        var model = "fake-claude"
        var args = Array(CommandLine.arguments.dropFirst())
        while !args.isEmpty {
            let arg = args.removeFirst()
            switch arg {
            case "--permission-mode":
                if !args.isEmpty { permissionMode = args.removeFirst() }
            case "--resume":
                if !args.isEmpty { resumeSessionID = args.removeFirst() }
            case "-r":
                if !args.isEmpty { resumeSessionID = args.removeFirst() }
            case "--model":
                if !args.isEmpty { model = args.removeFirst() }
            default:
                if arg.hasPrefix("--resume=") {
                    resumeSessionID = String(arg.dropFirst("--resume=".count))
                }
            }
        }
        return (permissionMode, resumeSessionID, model)
    }

    static func runAuthStatus() -> Int32 {
        let authenticated = ProcessInfo.processInfo.environment["CODEMIXER_TWIN_AUTH"] != "0"
        let body: [String: Any] = authenticated
            ? ["authenticated": true, "account": "twin@codemixer.local"]
            : ["authenticated": false]
        guard let data = try? JSONSerialization.data(withJSONObject: body) else { return 1 }
        FileHandle.standardOutput.write(data)
        FileHandle.standardOutput.write(Data("\n".utf8))
        return authenticated ? 0 : 1
    }
}
