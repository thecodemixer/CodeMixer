import SwiftUI
import AgentCore

private struct CodemixerAppearanceKey: EnvironmentKey {
    static let defaultValue = AppearancePrefs()
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
        codemixerAppearance.densityMode == "compact" ? 0.85 : 1.0
    }
}

public extension View {
    func codemixerAppearance(_ prefs: AppearancePrefs) -> some View {
        modifier(CodemixerAppearanceModifier(prefs: prefs))
    }
}

private struct CodemixerAppearanceModifier: ViewModifier {
    let prefs: AppearancePrefs

    private var colorScheme: ColorScheme? {
        switch prefs.theme {
        case "light": return .light
        case "dark": return .dark
        default: return nil
        }
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
            .dynamicTypeSize(dynamicTypeSize)
    }
}
