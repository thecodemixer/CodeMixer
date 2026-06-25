import SwiftUI

// MARK: - Pill / Tag / Badge — flat, no shadows.

/// Small flat capsule used for inline state.
public struct Pill: View {
    public let label: String
    public let tint: Color

    public init(label: String, tint: Color = Theme.text.tertiary) {
        self.label = label
        self.tint = tint
    }

    public var body: some View {
        Text(label)
            .font(Theme.typography.caption)
            .foregroundStyle(tint)
            .padding(.horizontal, Theme.spacing.s8)
            .padding(.vertical, 2)
            .background(tint.opacity(Theme.opacity.quiet), in: Capsule())
            .accessibilityLabel(label)
    }
}

/// Like `Pill` but with a leading SF Symbol — for resume/auto-approval flags.
public struct Tag: View {
    public let label: String
    public let system: String

    public init(label: String, system: String) {
        self.label = label
        self.system = system
    }

    public var body: some View {
        HStack(spacing: Theme.spacing.s4) {
            Image(systemName: system).font(Theme.typography.iconSmall)
                .accessibilityLabel("Status icon")
            Text(label).font(Theme.typography.caption)
        }
        .foregroundStyle(Theme.text.secondary)
        .padding(.horizontal, Theme.spacing.s8)
        .padding(.vertical, 3)
        .background(Theme.surface.bubble, in: Capsule())
    }
}

/// Small unread-style number badge.
public struct Badge: View {
    public let count: Int

    public init(count: Int) { self.count = count }

    public var body: some View {
        Text("\(count)")
            .font(Theme.typography.caption)
            .foregroundStyle(.white)
            .padding(.horizontal, 6)
            .padding(.vertical, 2)
            .background(Theme.signal.info, in: Capsule())
            .accessibilityLabel("\(count) items")
    }
}

// MARK: - Workspace + connected-clients chips for the top toolbar.

public struct WorkspaceChip: View {
    public let displayName: String

    public init(displayName: String) { self.displayName = displayName }

    public var body: some View {
        HStack(spacing: Theme.spacing.s4) {
            Image(systemName: "folder.fill")
                .accessibilityLabel("Project")
                .foregroundStyle(Theme.text.secondary)
            Text(displayName)
                .font(Theme.typography.label)
                .foregroundStyle(Theme.text.primary)
                .lineLimit(1)
        }
        .padding(.horizontal, Theme.spacing.s8)
        .padding(.vertical, Theme.spacing.s4)
        .background(Theme.surface.bubble, in: Capsule())
        .accessibilityLabel("Current project: \(displayName)")
    }
}

public struct ConnectedClientsChip: View {
    public let count: Int
    public let onTap: () -> Void

    public init(count: Int, onTap: @escaping () -> Void = {}) {
        self.count = count
        self.onTap = onTap
    }

    public var body: some View {
        if count > 0 {
            Button(action: onTap) {
                HStack(spacing: Theme.spacing.s4) {
                    Image(systemName: "antenna.radiowaves.left.and.right")
                        .accessibilityLabel("Remote connection")
                    Text("\(count) connected")
                        .font(Theme.typography.caption)
                }
                .padding(.horizontal, Theme.spacing.s8)
                .padding(.vertical, 3)
                .background(Theme.signal.info.opacity(Theme.opacity.muted), in: Capsule())
                .foregroundStyle(Theme.signal.info)
            }
            .buttonStyle(.plain)
            .help("\(count) remote client\(count == 1 ? "" : "s") attached. Click to open Settings → Remote.")
            .accessibilityLabel("\(count) remote clients attached")
        }
    }
}

// MARK: - Empty state.

public struct EmptyState: View {
    public let system: String
    public let title: String
    public let subtitle: String?

    public init(system: String, title: String, subtitle: String? = nil) {
        self.system = system
        self.title = title
        self.subtitle = subtitle
    }

    public var body: some View {
        VStack(spacing: Theme.spacing.s8) {
            Image(systemName: system)
                .accessibilityLabel("Status icon")
                .font(Theme.typography.emptyState)
                .foregroundStyle(Theme.text.tertiary)
            Text(title)
                .font(Theme.typography.label)
                .foregroundStyle(Theme.text.secondary)
            if let subtitle {
                Text(subtitle)
                    .font(Theme.typography.caption)
                    .foregroundStyle(Theme.text.tertiary)
                    .multilineTextAlignment(.center)
            }
        }
        .padding(Theme.spacing.s24)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .accessibilityElement(children: .combine)
    }
}

// MARK: - Toast.

public struct Toast: View {
    public enum Kind: Sendable { case info, success, warning, error }
    public let kind: Kind
    public let text: String
    public let action: (label: String, perform: () -> Void)?

    public init(kind: Kind, text: String,
                action: (label: String, perform: () -> Void)? = nil) {
        self.kind = kind
        self.text = text
        self.action = action
    }

    public var body: some View {
        HStack(spacing: Theme.spacing.s8) {
            Image(systemName: icon).foregroundStyle(tint)
                .accessibilityLabel("Tool call icon")
            Text(text).font(Theme.typography.caption)
            if let action {
                Spacer()
                Button(action.label, action: action.perform)
                    .buttonStyle(.borderless)
            }
        }
        .padding(.horizontal, Theme.spacing.s12)
        .padding(.vertical, Theme.spacing.s8)
        .background(Theme.surface.card, in: RoundedRectangle(cornerRadius: Theme.corner.medium))
        .overlay(RoundedRectangle(cornerRadius: Theme.corner.medium)
                    .stroke(tint.opacity(Theme.opacity.medium), lineWidth: Theme.stroke.hairline))
        .accessibilityLabel(text)
    }

    private var icon: String {
        switch kind { case .info: return "info.circle"; case .success: return "checkmark.circle"
        case .warning: return "exclamationmark.triangle"; case .error: return "xmark.octagon" }
    }
    private var tint: Color {
        switch kind { case .info: return Theme.signal.info; case .success: return Theme.signal.success
        case .warning: return Theme.signal.warning; case .error: return Theme.signal.danger }
    }
}

// MARK: - KbdKey — for tooltips and help text.

public struct KbdKey: View {
    public let glyph: String
    public init(_ glyph: String) { self.glyph = glyph }
    public var body: some View {
        Text(glyph)
            .font(.system(.caption2, design: .monospaced).weight(.semibold))
            .padding(.horizontal, 6)
            .padding(.vertical, 2)
            .background(Theme.surface.bubble, in: RoundedRectangle(cornerRadius: Theme.corner.chip))
            .overlay(RoundedRectangle(cornerRadius: Theme.corner.chip).stroke(Theme.surface.divider, lineWidth: Theme.stroke.hairline))
            .accessibilityLabel("Key \(glyph)")
    }
}

// MARK: - CodeBlock — used in tool renderers.

public struct CodeBlock: View {
    public let text: String
    public let language: String?

    public init(text: String, language: String? = nil) {
        self.text = text
        self.language = language
    }

    public var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            if let language {
                Text(language)
                    .font(Theme.typography.caption)
                    .foregroundStyle(Theme.text.tertiary)
                    .padding(.horizontal, Theme.spacing.s8)
                    .padding(.vertical, 4)
            }
            ScrollView(.horizontal, showsIndicators: false) {
                Text(text)
                    .font(Theme.typography.monoSmall)
                    .foregroundStyle(Theme.text.primary)
                    .padding(Theme.spacing.s8)
                    .textSelection(.enabled)
            }
        }
        .background(Theme.surface.canvas, in: RoundedRectangle(cornerRadius: Theme.corner.small))
        .overlay(RoundedRectangle(cornerRadius: Theme.corner.small)
                    .stroke(Theme.surface.divider, lineWidth: Theme.stroke.hairline))
    }
}
