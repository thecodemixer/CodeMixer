import SwiftUI
import Testing
@testable import AgentUI
import AgentCore

/// `.focus` is the chat workbench's zen density preset — it must share
/// `.compact`'s spacing scale (its distinguishing behavior, lane collapse,
/// is handled by the workbench itself, not by spacing).
@Suite("codemixerSpacingScale — density mapping")
struct AppearanceModifiersTests {

    @Test("comfortable is unscaled; compact and focus both scale to 0.85")
    func densityMapsToExpectedScale() {
        #expect(scale(for: .comfortable) == 1.0)
        #expect(scale(for: .compact) == 0.85)
        #expect(scale(for: .focus) == 0.85)
    }

    private func scale(for density: Theme.DensityMode) -> CGFloat {
        var env = EnvironmentValues()
        var prefs = AppearancePrefs()
        prefs.densityMode = density
        env.codemixerAppearance = prefs
        return env.codemixerSpacingScale
    }
}
