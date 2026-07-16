import Foundation
import OSLog

/// Always-on journal of silent recovery actions (quiet-reset, re-pair, cert
/// rotate, Mode B fallback, WireVersion reject, and similar).
///
/// Records are mirrored to `os.Logger` and retained in a bounded in-memory
/// ring so opt-in UI and the HTTP sidecar can expose them without toasts.
public actor SilentDiagnostics {

    public enum Kind: String, Sendable, Codable, CaseIterable {
        case prefsQuietReset
        case sessionsQuietReset
        case workspacesQuietReset
        case workspacesSchemaTooNew
        case prefsKeyDropped
        case pairedDevicesQuietReset
        case certificateRotated
        case wireVersionRejected
        case modeBFallback
        case enginePartialStartRollback
        case permissionDeliveryFailed
        case other
    }

    public struct Record: Sendable, Codable, Identifiable, Equatable {
        public let id: UUID
        public let timestamp: Date
        public let kind: Kind
        public let owner: String
        public let summary: String
        public let details: String?

        public init(id: UUID,
                    timestamp: Date,
                    kind: Kind,
                    owner: String,
                    summary: String,
                    details: String? = nil) {
            self.id = id
            self.timestamp = timestamp
            self.kind = kind
            self.owner = owner
            self.summary = summary
            self.details = details
        }
    }

    public static let shared = SilentDiagnostics()

    private let log = Logger(subsystem: AppIdentity.logSubsystem, category: "SilentDiagnostics")
    private let clock: any AgentClock
    private let random: any RandomSource
    private let capacity: Int
    private var ring: [Record] = []

    public init(clock: any AgentClock = SystemClock(),
                random: any RandomSource = SystemRandomSource(),
                capacity: Int = StreamBufferDefaults.silentDiagnostics) {
        precondition(capacity > 0)
        self.clock = clock
        self.random = random
        self.capacity = capacity
    }

    /// Append a silent-recovery record and mirror it to the system log.
    @discardableResult
    public func record(kind: Kind,
                       owner: String,
                       summary: String,
                       details: String? = nil) -> Record {
        let entry = Record(id: random.uuid(),
                           timestamp: clock.now(),
                           kind: kind,
                           owner: owner,
                           summary: summary,
                           details: details)
        ring.append(entry)
        if ring.count > capacity {
            ring.removeFirst(ring.count - capacity)
        }
        log.notice("silent \(kind.rawValue, privacy: .public) owner=\(owner, privacy: .public) \(summary, privacy: .public)")
        return entry
    }

    /// Oldest-first snapshot of the ring.
    public func snapshot() -> [Record] { ring }

    /// Drop all retained records (tests / explicit clear).
    public func clear() {
        ring.removeAll(keepingCapacity: false)
    }
}
