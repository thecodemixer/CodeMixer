import Foundation

/// Builds an `AgentAdapter` for a user-configured custom agent.
///
/// Registered from Bootstrap / daemon so `AgentCore` stays free of concrete
/// adapter imports. Returns `nil` when the transport is unsupported.
public protocol CustomAgentAdapterFactory: Sendable {
    func makeAdapter(for ref: CustomAgentRef) -> (any AgentAdapter)?
}

/// Process-wide custom-adapter factory registry.
public actor CustomAgentAdapterFactories {
    public static let shared = CustomAgentAdapterFactories()

    private var factories: [any CustomAgentAdapterFactory] = []

    public func register(_ factory: any CustomAgentAdapterFactory) {
        factories.append(factory)
    }

    public func makeAdapter(for ref: CustomAgentRef) -> (any AgentAdapter)? {
        for factory in factories {
            if let adapter = factory.makeAdapter(for: ref) {
                return adapter
            }
        }
        return nil
    }

    /// Test-only reset.
    public func resetForTests() {
        factories.removeAll()
    }
}
