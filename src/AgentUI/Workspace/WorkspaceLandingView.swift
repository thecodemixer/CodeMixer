import SwiftUI
import AgentCore

/// Full-window landing shown before chat is available: either no workspace is
/// open yet, or a workspace shell exists but has no registered projects.
public struct WorkspaceLandingView: View {
    public let systemImage: String
    /// When set, shown above `title` as the primary focal line (e.g. workspace folder name).
    public var prominentName: String?
    public let title: String
    public let subtitle: String
    public let primaryButtonTitle: String
    public let primaryAction: () -> Void
    public var primaryKeyboardShortcut: KeyEquivalent?
    public var primaryKeyboardModifiers: EventModifiers = .command
    public var secondaryButtonTitle: String?
    public var secondaryAction: (() -> Void)?
    public var secondaryKeyboardShortcut: KeyEquivalent?
    public var secondaryKeyboardModifiers: EventModifiers = .command

    public init(systemImage: String,
                prominentName: String? = nil,
                title: String,
                subtitle: String,
                primaryButtonTitle: String,
                primaryAction: @escaping () -> Void,
                primaryKeyboardShortcut: KeyEquivalent? = nil,
                primaryKeyboardModifiers: EventModifiers = .command,
                secondaryButtonTitle: String? = nil,
                secondaryAction: (() -> Void)? = nil,
                secondaryKeyboardShortcut: KeyEquivalent? = nil,
                secondaryKeyboardModifiers: EventModifiers = .command) {
        self.systemImage = systemImage
        self.prominentName = prominentName
        self.title = title
        self.subtitle = subtitle
        self.primaryButtonTitle = primaryButtonTitle
        self.primaryAction = primaryAction
        self.primaryKeyboardShortcut = primaryKeyboardShortcut
        self.primaryKeyboardModifiers = primaryKeyboardModifiers
        self.secondaryButtonTitle = secondaryButtonTitle
        self.secondaryAction = secondaryAction
        self.secondaryKeyboardShortcut = secondaryKeyboardShortcut
        self.secondaryKeyboardModifiers = secondaryKeyboardModifiers
    }

    public var body: some View {
        VStack(spacing: Theme.spacing.s16) {
            Image(systemName: systemImage)
                .accessibilityHidden(true)
                .font(Theme.typography.heroIcon)
                .foregroundStyle(Theme.text.tertiary)

            VStack(spacing: Theme.spacing.s8) {
                if let prominentName {
                    Text(prominentName)
                        .font(Theme.typography.title)
                        .foregroundStyle(Theme.text.primary)
                        .multilineTextAlignment(.center)
                        .lineLimit(2)
                        .minimumScaleFactor(0.8)
                        .accessibilityAddTraits(.isHeader)
                }
                Text(title)
                    .font(prominentName == nil ? Theme.typography.title : Theme.typography.label)
                    .foregroundStyle(prominentName == nil ? Theme.text.primary : Theme.text.secondary)
                Text(subtitle)
                    .font(Theme.typography.body)
                    .foregroundStyle(Theme.text.secondary)
                    .multilineTextAlignment(.center)
                    .frame(maxWidth: Theme.layout.messageMaxWidth)
            }

            actionButtons
        }
        .padding(Theme.spacing.s24)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Theme.surface.canvas)
    }

    @ViewBuilder
    private var actionButtons: some View {
        HStack(spacing: Theme.spacing.s12) {
            if let secondaryButtonTitle, let secondaryAction {
                secondaryButton(title: secondaryButtonTitle, action: secondaryAction)
            }
            primaryButton
        }
    }

    @ViewBuilder
    private var primaryButton: some View {
        if let primaryKeyboardShortcut {
            Button(primaryButtonTitle, action: primaryAction)
                .buttonStyle(.borderedProminent)
                .keyboardShortcut(primaryKeyboardShortcut, modifiers: primaryKeyboardModifiers)
                .accessibilityLabel(primaryButtonTitle)
        } else {
            Button(primaryButtonTitle, action: primaryAction)
                .buttonStyle(.borderedProminent)
                .accessibilityLabel(primaryButtonTitle)
        }
    }

    @ViewBuilder
    private func secondaryButton(title: String, action: @escaping () -> Void) -> some View {
        if let secondaryKeyboardShortcut {
            Button(title, action: action)
                .buttonStyle(.bordered)
                .keyboardShortcut(secondaryKeyboardShortcut, modifiers: secondaryKeyboardModifiers)
                .accessibilityLabel(title)
        } else {
            Button(title, action: action)
                .buttonStyle(.bordered)
                .accessibilityLabel(title)
        }
    }
}
