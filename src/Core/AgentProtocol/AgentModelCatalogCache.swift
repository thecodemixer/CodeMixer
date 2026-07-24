import Foundation

/// Thread-safe snapshot of adapter model options loaded from workspace cache or
/// adapter-specific discovery.
/// Safety: every read and write of mutable `models` is protected by `lock`.
public final class AgentModelCatalogCache: @unchecked Sendable {
    private let lock = NSLock()
    private var models: [AgentModelOption]

    public init(models: [AgentModelOption]) {
        self.models = models
    }

    public func snapshot() -> [AgentModelOption] {
        lock.lock()
        defer { lock.unlock() }
        return models
    }

    public func replace(with models: [AgentModelOption]) {
        lock.lock()
        defer { lock.unlock() }
        self.models = models
    }
}
