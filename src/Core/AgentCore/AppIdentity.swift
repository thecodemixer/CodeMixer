import Foundation

/// Central identity strings for Codemixer.
///
/// Product-owned identifiers live here so loggers, Keychain services,
/// LaunchAgents, and support directories do not drift through copy-paste.
public enum AppIdentity {
    public static let bundleIdentifier = "com.codecave.Codemixer"
    public static let logSubsystem = bundleIdentifier
    public static let displayName = "Codemixer"

    public static let launchAgentLabel = "\(bundleIdentifier).daemon"
    public static let launchAgentPlistName = "\(launchAgentLabel).plist"
    public static let pairedDevicesService = "\(bundleIdentifier).pairedDevices"
    public static let remoteCertificatePasswordService = "\(bundleIdentifier).remoteCertPassword"
    public static let tlsPinQueueLabel = "\(bundleIdentifier).tls.pin"
    public static let ptyReadQueueLabel = "\(bundleIdentifier).pty.read"
    public static let fallbackDeviceName = "Mac"

    public static let appSupportRelativePath =
        "Library/Application Support/\(bundleIdentifier)"
    public static let cachesRelativePath = "Library/Caches/\(displayName)"
}
