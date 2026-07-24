import SwiftUI
import AgentCore

struct ToolCallCardView: View {
    let entry: EngineViewModel.ToolCallEntry

    @State private var expanded = false

    var body: some View {
        VStack(alignment: .leading, spacing: Theme.spacing.s8) {
            HStack(spacing: Theme.spacing.s8) {
                Image(systemName: icon)
                    .accessibilityLabel("Tool call icon")
                    .foregroundStyle(iconTint)
                Text(entry.input.summary)
                    .font(Theme.typography.label)
                    .foregroundStyle(Theme.text.primary)
                    .lineLimit(1)
                Spacer()
                Text(state)
                    .font(Theme.typography.caption)
                    .foregroundStyle(Theme.text.tertiary)
            }
            .contentShape(Rectangle())
            .onTapGesture { withAnimation(Theme.motion.quick) { expanded.toggle() } }

            if expanded, let payload = entry.input.jsonPayload {
                Text(payload)
                    .font(Theme.typography.monoSmall)
                    .fontDesign(.monospaced)
                    .foregroundStyle(Theme.text.secondary)
                    .padding(Theme.spacing.s8)
                    .background(Theme.surface.canvas,
                                in: RoundedRectangle(cornerRadius: Theme.corner.small))
            }

            // Subagent nested conversation (surfaces via .toolProgress(.generic)).
            if expanded, !entry.subagentLines.isEmpty {
                VStack(alignment: .leading, spacing: Theme.spacing.s4) {
                    Label("Subagent", systemImage: "cpu.fill")
                        .font(Theme.typography.caption)
                        .foregroundStyle(Theme.signal.info)
                        .accessibilityLabel("Subagent output")
                    ForEach(Array(entry.subagentLines.enumerated()), id: \.offset) { _, line in
                        Text(line)
                            .font(Theme.typography.monoSmall)
                            .fontDesign(.monospaced)
                            .foregroundStyle(Theme.text.secondary)
                            .padding(.horizontal, Theme.spacing.s8)
                            .padding(.vertical, Theme.spacing.s4)
                            .background(Theme.surface.bubble,
                                        in: RoundedRectangle(cornerRadius: Theme.corner.small))
                            .textSelection(.enabled)
                    }
                }
                .padding(.top, Theme.spacing.s4)
            }

            if expanded, let output = entry.output {
                let summary = output.errorMessage ?? output.summary
                Text(summary)
                    .font(Theme.typography.caption)
                    .foregroundStyle(output.errorMessage != nil ? Theme.signal.danger : Theme.text.secondary)
                    .textSelection(.enabled)
                if let payload = output.jsonPayload {
                    Text(payload)
                        .font(Theme.typography.monoSmall)
                        .fontDesign(.monospaced)
                        .foregroundStyle(Theme.text.secondary)
                        .padding(Theme.spacing.s8)
                        .background(Theme.surface.canvas,
                                    in: RoundedRectangle(cornerRadius: Theme.corner.small))
                        .textSelection(.enabled)
                }
            }
        }
        .padding(Theme.spacing.s12)
        .background(Theme.surface.card,
                    in: RoundedRectangle(cornerRadius: Theme.corner.medium))
        .overlay(RoundedRectangle(cornerRadius: Theme.corner.medium)
                    .stroke(Theme.surface.divider, lineWidth: Theme.stroke.hairline))
        .accessibilityLabel(accessibilityLabel)
    }

    // MARK: -

    private var icon: String {
        switch entry.name.lowercased() {
        case "bash":                          return "terminal"
        case "edit", "write", "multiedit":    return "pencil"
        case "read":                          return "doc.text"
        case "grep", "glob":                  return "magnifyingglass"
        case "webfetch", "websearch":         return "network"
        default:                              return "wrench.and.screwdriver"
        }
    }

    private var iconTint: Color {
        switch entry.phase {
        case .running: return Theme.signal.info
        case .succeeded: return Theme.signal.success
        case .failed: return Theme.signal.danger
        }
    }

    private var state: String {
        switch entry.phase {
        case .running: return "Running…"
        case .succeeded: return "Done"
        case .failed: return "Failed"
        }
    }

    private var accessibilityLabel: String {
        "\(entry.name) tool, \(state). \(entry.input.summary)"
    }

    private var output: String? {
        guard let out = entry.output else { return nil }
        return out.errorMessage ?? out.summary
    }
}

/// A tool call's lifecycle stage. Computed from `ToolCallEntry.finished`/
/// `success` rather than stored alongside them — there's no third flag that
/// can fall out of sync with those two.
enum ToolCallPhase: Equatable {
    case running(progress: ToolProgress?)
    case succeeded
    case failed
}

extension EngineViewModel.ToolCallEntry {
    var displayName: String {
        name.first.map { "\(String($0).uppercased())\(name.dropFirst())" } ?? name
    }

    var phase: ToolCallPhase {
        guard finished else { return .running(progress: progress) }
        return success ? .succeeded : .failed
    }
}
