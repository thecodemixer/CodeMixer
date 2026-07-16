import Foundation

/// Headless `codemixerd` lifecycle policy.
///
/// The daemon exits after sustained idle with no connected clients so a
/// LaunchAgent install does not leave a forever-running process.
public enum DaemonDefaults {
    public static let idleCheckInterval: Duration = .seconds(60)
    public static let idleExitAfterChecks = 10
}
