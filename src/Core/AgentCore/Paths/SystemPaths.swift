import Foundation

/// Fixed macOS system binary locations used by engine and remote-control code.
///
/// These paths are stable on macOS; centralising them keeps audit greps simple.
public enum SystemPaths {
    public static let env = URL(fileURLWithPath: "/usr/bin/env")
    public static let git = URL(fileURLWithPath: "/usr/bin/git")
    public static let openssl = URL(fileURLWithPath: "/usr/bin/openssl")
    public static let python3 = URL(fileURLWithPath: "/usr/bin/python3")
    public static let terminalApp = URL(fileURLWithPath: "/System/Applications/Utilities/Terminal.app")
}
