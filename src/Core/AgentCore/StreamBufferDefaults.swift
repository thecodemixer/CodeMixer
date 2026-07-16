import Foundation

/// Named AsyncStream buffer sizes used across engine-side streams.
///
/// The values are intentionally layer-specific: PTY and hook streams favor
/// preserving bursts, network streams stay small, and FSEvents gets room for
/// filesystem storms before the watcher debounces work.
public enum StreamBufferDefaults {
    public static let eventHistory = 500
    public static let adapterEvents = 512
    public static let ptyChunks = 256
    public static let hookRequests = 256
    public static let transcriptEvents = 256
    public static let terminalReplies = 64
    public static let networkConnections = 64
    public static let speechEvents = 64
    public static let fileSystemEvents = 1024
    /// Bounded SilentDiagnostics ring — enough for a session of quiet recoveries.
    public static let silentDiagnostics = 200
}
