import Foundation

import AgentCore

/// Maps the migration tool's file-level pipeline status string — delivered
/// over the wire as `codemixer.dev/phase_update` — onto the agent-agnostic
/// `SessionPhase` the chat workbench's index rail groups by. An explicit
/// table (not a hash of the vendor string) so an unrecognized status
/// degrades to a visible, ordinal-less `.plan` entry instead of silently
/// sorting into the wrong rail group.
enum ACPPipelinePhaseMapping {
    static func phase(forStatus status: String) -> SessionPhase {
        switch status {
        case "pending":
            return SessionPhase(id: status, label: "Pending", ordinal: 0, group: .plan)
        case "planned":
            return SessionPhase(id: status, label: "Planned", ordinal: 1, group: .plan)
        case "migrating":
            return SessionPhase(id: status, label: "Migrating", ordinal: 2, group: .migrate)
        case "migrated":
            return SessionPhase(id: status, label: "Migrated", ordinal: 3, group: .migrate)
        case "reviewing":
            return SessionPhase(id: status, label: "Reviewing", ordinal: 4, group: .review)
        case "fixing":
            return SessionPhase(id: status, label: "Fixing", ordinal: 5, group: .fix)
        case "approved":
            return SessionPhase(id: status, label: "Approved", ordinal: 6, group: .review)
        case "verified":
            return SessionPhase(id: status, label: "Verified", ordinal: 7, group: .verify)
        case "needs-human-review":
            return SessionPhase(id: status, label: "Needs Review", ordinal: 8, group: .review)
        default:
            return SessionPhase(id: status, label: status.capitalized, ordinal: -1, group: .plan)
        }
    }
}
