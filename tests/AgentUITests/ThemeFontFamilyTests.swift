import Testing
@testable import AgentUI
import AgentCore

@Suite("Theme.FontFamily — design mapping")
struct ThemeFontFamilyTests {

    @Test("Every family maps to a distinct SwiftUI font design")
    func everyFamilyMapsToADesign() {
        #expect(Theme.FontFamily.system.design == .default)
        #expect(Theme.FontFamily.rounded.design == .rounded)
        #expect(Theme.FontFamily.serif.design == .serif)
    }

    @Test("Raw values round-trip through the stored string prefs field")
    func rawValueRoundTrips() {
        for family in Theme.FontFamily.allCases {
            #expect(Theme.FontFamily(rawValue: family.rawValue) == family)
        }
    }

    @Test("Every family has a non-empty display name for the settings picker")
    func everyFamilyHasADisplayName() {
        for family in Theme.FontFamily.allCases {
            #expect(!family.displayName.isEmpty)
        }
    }
}
