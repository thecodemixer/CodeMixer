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

    public static let zsh = URL(fileURLWithPath: "/bin/zsh")
    public static let bash = URL(fileURLWithPath: "/bin/bash")
    public static let sh = URL(fileURLWithPath: "/bin/sh")
    public static let echo = URL(fileURLWithPath: "/bin/echo")
    public static let cat = URL(fileURLWithPath: "/bin/cat")
    public static let pwd = URL(fileURLWithPath: "/bin/pwd")
    public static let sleep = URL(fileURLWithPath: "/bin/sleep")
    public static let trueBinary = URL(fileURLWithPath: "/usr/bin/true")
    public static let falseBinary = URL(fileURLWithPath: "/usr/bin/false")

    public static let homebrewBin = URL(fileURLWithPath: "/opt/homebrew/bin", isDirectory: true)
    public static let usrLocalBin = URL(fileURLWithPath: "/usr/local/bin", isDirectory: true)

    /// Stable `/private` prefix for realpath-normalized macOS paths.
    public static let privatePrefix = "/private"

    public static let standardPathList = "/usr/bin:/bin:/usr/sbin:/sbin"
    public static let usrBinAndBinPath = "/usr/bin:/bin"
    public static let usrBinPath = "/usr/bin"

    public static func binary(in directory: URL, named name: String) -> URL {
        directory.appendingPathComponent(name)
    }
}
