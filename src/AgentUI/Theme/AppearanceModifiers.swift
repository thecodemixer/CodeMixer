import SwiftUI
import AgentCore

private struct CodemixerAppearanceKey: EnvironmentKey {
    static let defaultValue = AppearancePrefs()
}

private struct FloatingCornerRadiusKey: EnvironmentKey {
    static let defaultValue = Theme.corner.floating
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

private struct FloatingPopoverChromeModifier: ViewModifier {
    @Environment(\.codemixerFloatingCornerRadius) private var radius

    func body(content: Content) -> some View {
        content.presentationCornerRadius(radius)
    }
}
