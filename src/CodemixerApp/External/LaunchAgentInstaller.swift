import Foundation
import Darwin
import AgentCore

/// Installs and removes the user LaunchAgent for `codemixerd`.
///
/// This is the app boundary for `launchctl` and plist writes; SwiftUI only sees
/// success/failure text through `RemoteSettingsState`.
actor LaunchAgentInstaller {
    enum InstallError: Error, Sendable {
        case writeFailed(String)
        case launchctlFailed(String)
    }

    private let fileSystem: any FileSystem
    private let processRunner: ProcessRunner
    private let environment: any AgentEnvironment

    init(environment: any AgentEnvironment = SystemEnvironment(),
         fileSystem: any FileSystem = SystemFileSystem(),
         processRunner: ProcessRunner = ProcessRunner()) {
        self.environment = environment
        self.fileSystem = fileSystem
        self.processRunner = processRunner
    }

    var isInstalled: Bool {
        fileSystem.fileExists(at: plistURL)
    }

    func install() async throws {
        do {
            try fileSystem.createDirectory(at: launchAgentsDirectory, withIntermediates: true)
            try fileSystem.writeAtomically(Data(plistText.utf8), to: plistURL)
        } catch {
            throw InstallError.writeFailed(String(describing: error))
        }
        try await runLaunchctl(["bootstrap", "gui/\(getuid())", plistURL.path])
    }

    func uninstall() async throws {
        _ = try? await runLaunchctl(["bootout", "gui/\(getuid())", plistURL.path])
        do {
            if fileSystem.fileExists(at: plistURL) {
                try fileSystem.remove(at: plistURL)
            }
        } catch {
            throw InstallError.writeFailed(String(describing: error))
        }
    }

    private var launchAgentsDirectory: URL {
        environment.homeDirectory
            .appendingPathComponent("Library/LaunchAgents", isDirectory: true)
    }

    private var plistURL: URL {
        launchAgentsDirectory.appendingPathComponent(AppIdentity.launchAgentPlistName)
    }

    private var daemonPath: String {
        if let appSibling = Bundle.main.executableURL?
            .deletingLastPathComponent()
            .appendingPathComponent("codemixerd"),
           fileSystem.fileExists(at: appSibling) {
            return appSibling.path
        }
        return "/usr/local/bin/codemixerd"
    }

    private var plistText: String {
        """
        <?xml version="1.0" encoding="UTF-8"?>
        <!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
        <plist version="1.0">
        <dict>
            <key>Label</key>
            <string>\(AppIdentity.launchAgentLabel)</string>
            <key>ProgramArguments</key>
            <array>
                <string>\(daemonPath)</string>
            </array>
            <key>RunAtLoad</key>
            <true/>
            <key>KeepAlive</key>
            <dict>
                <key>SuccessfulExit</key>
                <false/>
            </dict>
            <key>StandardOutPath</key>
            <string>/tmp/codemixerd.stdout</string>
            <key>StandardErrorPath</key>
            <string>/tmp/codemixerd.stderr</string>
            <key>ThrottleInterval</key>
            <integer>30</integer>
        </dict>
        </plist>
        """
    }

    private func runLaunchctl(_ arguments: [String]) async throws {
        do {
            _ = try await processRunner.run(executable: URL(fileURLWithPath: "/bin/launchctl"),
                                            arguments: arguments)
        } catch let ProcessRunner.ProcessError.nonZeroExit(_, stderr) {
            throw InstallError.launchctlFailed(stderr)
        } catch {
            throw InstallError.launchctlFailed(String(describing: error))
        }
    }
}
