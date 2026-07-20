import Foundation

import AgentClientProtocol
import AgentCore

/// Builds cached `CustomACPAdapter` instances for ACP custom projects.
public final class CustomACPAdapterFactory: CustomAgentAdapterFactory, @unchecked Sendable {
    private let lock = NSLock()
    private var cache: [String: Cached] = [:]

    private struct Cached {
        let ref: CustomAgentRef
        let adapter: CustomACPAdapter
    }

    public init() {}

    public func makeAdapter(for ref: CustomAgentRef) -> (any AgentAdapter)? {
        guard ref.transport.kind == .agentClientProtocol else { return nil }
        lock.lock()
        defer { lock.unlock() }
        if let existing = cache[ref.id], existing.ref == ref {
            return existing.adapter
        }
        let adapter = CustomACPAdapter(ref: ref)
        cache[ref.id] = Cached(ref: ref, adapter: adapter)
        return adapter
    }

    /// Test helper — clears the process-wide cache held by this factory instance.
    public func resetCacheForTests() {
        lock.lock()
        cache.removeAll()
        lock.unlock()
    }
}
