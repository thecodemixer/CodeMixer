import Foundation
import AgentCore

/// Pinned-environment fake. Default values mimic a typical macOS user
/// without surfacing the real `$HOME`.
public struct FakeEnvironment: AgentEnvironment {
    public var processEnv: [String: String]
    public let homeDirectory: URL
    public let appSupportDirectory: URL
    public let cachesDirectory: URL
    public let claudeDirectory: URL
    public let deviceName: String

    public init(processEnv: [String: String] = [:],
                home: URL = URL(fileURLWithPath: NSTemporaryDirectory() + "fake-home", isDirectory: true),
                deviceName: String = "FakeMac") {
        self.processEnv = processEnv
        self.homeDirectory = home
        self.appSupportDirectory = home.appendingPathComponent(AppIdentity.appSupportRelativePath, isDirectory: true)
        self.cachesDirectory = home.appendingPathComponent("Library/Caches/Codemixer", isDirectory: true)
        self.claudeDirectory = home.appendingPathComponent(".claude", isDirectory: true)
        self.deviceName = deviceName
    }

    public func processEnvironment() -> [String: String] { processEnv }
}
