import SwiftUI
import AgentCore
import AgentProtocol

/// Model picker in the composer bottom bar.
struct ComposerModelMenu: View {
    @Bindable var model: EngineViewModel
    @Binding var selectedModelID: String
    @Binding var isOpen: Bool
    let closeOtherMenus: () -> Void

    @State private var menuHeight: CGFloat = 0
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    /// Vertical gap between the dropdown panel and its trigger button.
    private static let dropdownGap: CGFloat = Theme.spacing.s4

    private var selectedModelLabel: String {
        model.availableModels.first { $0.id == selectedModelID }?.label
            ?? model.availableModels.first?.label
            ?? "Model"
    }

    var body: some View {
        Button {
            toggleMenu()
        } label: {
            menuLabel
        }
        .buttonStyle(.plain)
        .fixedSize()
        .accessibilityLabel("Model \(selectedModelLabel)")
        .overlay(alignment: .top) {
            if isOpen {
                ComposerDropdownPanel(
                    options: model.availableModels.map { option in
                        ComposerDropdownOption(id: option.id, title: option.label,
                                              isSelected: option.id == selectedModelID) {
                            selectedModelID = option.id
                            model.selectModel(id: option.id, label: option.label)
                            isOpen = false
                        }
                    },
                    minWidth: Theme.layout.composerModelPickerMinWidth,
                    isSearchable: true,
                    maxHeight: Theme.layout.composerModelPickerMaxHeight,
                    onDismiss: { isOpen = false }
                )
                .positionedAboveAnchor(height: $menuHeight, gap: Self.dropdownGap)
                .transition(.opacity)
                .zIndex(1)
            }
        }
    }

    private var menuLabel: some View {
        HStack(spacing: Theme.spacing.s4) {
            Text(selectedModelLabel)
                .font(Theme.typography.label)
                .lineLimit(1)
            Image(systemName: "chevron.down")
                .accessibilityHidden(true)
                .font(Theme.typography.iconSmall)
                .foregroundStyle(Theme.text.tertiary.opacity(Theme.opacity.secondary))
        }
        .frame(minWidth: Theme.layout.composerModelPickerMinWidth, alignment: .leading)
        .padding(.top, Theme.spacing.s4)
        .padding(.bottom, CGFloat.zero)
        .padding(.horizontal, Theme.spacing.s4)
        .contentShape(Rectangle())
        .foregroundStyle(Theme.text.secondary)
    }

    private func toggleMenu() {
        let animation = Theme.motion.resolve(Theme.motion.arriving, reduceMotion: reduceMotion)
        withAnimation(animation) {
            closeOtherMenus()
            isOpen.toggle()
        }
    }
}
