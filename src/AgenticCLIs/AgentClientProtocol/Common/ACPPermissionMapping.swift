import Foundation

import AgentProtocol

/// Maps Codemixer permission decisions onto ACP permission option kinds.
public enum ACPPermissionMapping {
    public static func optionID(for decision: PermissionDecision,
                                options: [String: String]) -> String? {
        switch decision {
        case .allowAlways:
            return options["allow_always"] ?? options["allow_once"]
        case .allow:
            return options["allow_once"] ?? options["allow_always"]
        case .deny:
            return options["reject_once"] ?? options["reject_always"]
        }
    }
}
