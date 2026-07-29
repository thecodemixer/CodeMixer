import Foundation

/// Shared literals for ACP digital-twin executables and integration tests.
public enum ACPTwinFixtures {
    public static let fsReadProbeFileName = "probe.txt"

    public static func fsReadProbePath(workspacePath: String?, fallback: String = "/tmp") -> String {
        (workspacePath ?? fallback).appending("/\(fsReadProbeFileName)")
    }
}
