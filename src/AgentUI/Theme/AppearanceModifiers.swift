import SwiftUI
import AgentCore

private struct CodemixerAppearanceKey: EnvironmentKey {
    static let defaultValue = AppearancePrefs()
}

private struct FloatingCornerRadiusKey: EnvironmentKey {
    static let defaultValue = Theme.corner.floating
}

private struct DropdownCornerRadiusKey: EnvironmentKey {
    static let defaultValue = Theme.corner.dropdown
}

public extension EnvironmentValues {
    var codemixerAppearance: AppearancePrefs {
        get { self[CodemixerAppearanceKey.self] }
        set { self[CodemixerAppearanceKey.self] = newValue }
    }

    /// User pref OR system accessibility setting — whichever requests less motion.
    /// UI-only: does not alter engine `noEventGap` timing (see `ActivityTiming`).
    var effectiveReduceMotion: Bool {
        codemixerAppearance.reduceMotion || accessibilityReduceMotion
    }

    /// Spacing multiplier derived from density mode (`compact` → 0.85).
    var codemixerSpacingScale: CGFloat {
        codemixerAppearance.densityMode == .compact ? 0.85 : 1.0
    }

    /// Resolved corner radius for popovers, palettes, and dropdown panels.
    var codemixerFloatingCornerRadius: CGFloat {
        get { self[FloatingCornerRadiusKey.self] }
        set { self[FloatingCornerRadiusKey.self] = newValue }
    }

    /// Composer bar dropdowns (mode/model) — half the floating radius.
    var codemixerDropdownCornerRadius: CGFloat {
        get { self[DropdownCornerRadiusKey.self] }
        set { self[DropdownCornerRadiusKey.self] = newValue }
    }
}

public extension View {
    func codemixerAppearance(_ prefs: AppearancePrefs) -> some View {
        modifier(CodemixerAppearanceModifier(prefs: prefs))
    }

    /// Card background + hairline stroke for a floating panel (palette, popover).
    func floatingPanelStyle() -> some View {
        modifier(FloatingPanelStyleModifier())
    }

    /// Applies the configured corner radius to a SwiftUI popover's chrome.
    func floatingPopoverChrome() -> some View {
        modifier(FloatingPopoverChromeModifier())
    }
}

private struct CodemixerAppearanceModifier: ViewModifier {
    let prefs: AppearancePrefs

    private var colorScheme: ColorScheme? {
        switch prefs.theme {
        case .light: return .light
        case .dark: return .dark
        case .system: return nil
        }
    }

    private var fontDesign: Font.Design {
        prefs.fontFamily.design
    }

    private var floatingCornerRadius: CGFloat {
        prefs.floatingCornerStyle.radius
    }

    private var dropdownCornerRadius: CGFloat {
        prefs.floatingCornerStyle.dropdownRadius
    }

    private var dynamicTypeSize: DynamicTypeSize {
        switch prefs.fontSizeScale {
        case ..<0.9: return .small
        case 0.9..<1.0: return .medium
        case 1.0..<1.15: return .large
        case 1.15..<1.3: return .xLarge
        default: return .xxLarge
        }
    }

    func body(content: Content) -> some View {
        content
            .preferredColorScheme(colorScheme)
            .environment(\.codemixerAppearance, prefs)
            .environment(\.codemixerFloatingCornerRadius, floatingCornerRadius)
            .environment(\.codemixerDropdownCornerRadius, dropdownCornerRadius)
            .dynamicTypeSize(dynamicTypeSize)
            .fontDesign(fontDesign)
    }
}

private struct FloatingPanelStyleModifier: ViewModifier {
    @Environment(\.codemixerFloatingCornerRadius) private var radius

    func body(content: Content) -> some View {
        content
            .background(Theme.surface.card,
                        in: RoundedRectangle(cornerRadius: radius, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: radius, style: .continuous)
                    .stroke(Theme.surface.divider, lineWidth: Theme.stroke.hairline)
            )
    }
}

/// `.popover`'s default system chrome (background material + arrow) tracks
/// the real macOS appearance, not this app's `preferredColorScheme`
/// override — so a popover can render light chrome inside a dark-themed
/// window. Reapplying `preferredColorScheme` here forces that popover's own
/// hosting context (and any `Color(nsColor:)` tokens drawn inside it) to
/// match, and `presentationBackground` replaces the system material outright
/// so there's exactly one themed background layer behind the system arrow.
private struct FloatingPopoverChromeModifier: ViewModifier {
    @Environment(\.codemixerFloatingCornerRadius) private var radius
    @Environment(\.colorScheme) private var colorScheme

    func body(content: Content) -> some View {
        content
            .preferredColorScheme(colorScheme)
            .presentationCornerRadius(radius)
            .presentationBackground {
                RoundedRectangle(cornerRadius: radius, style: .continuous)
                    .fill(Theme.surface.card)
                    .overlay(
                        RoundedRectangle(cornerRadius: radius, style: .continuous)
                            .stroke(Theme.surface.divider, lineWidth: Theme.stroke.hairline)
                    )
            }
    }
}
