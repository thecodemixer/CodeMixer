import Foundation
import Testing
@testable import AgentCore

@Suite("Theme — appearance enums")
struct ThemeAppearanceEnumTests {

    @Test("FloatingCornerStyle maps to expected radii")
    func floatingCornerRadii() {
        #expect(Theme.FloatingCornerStyle.sharp.radius == Theme.corner.small)
        #expect(Theme.FloatingCornerStyle.standard.radius == Theme.corner.floating)
        #expect(Theme.FloatingCornerStyle.soft.radius == Theme.corner.medium)
        #expect(Theme.FloatingCornerStyle.standard.dropdownRadius == Theme.corner.dropdown)
    }

    @Test("Every appearance enum round-trips through Codable")
    func appearanceEnumsRoundTrip() throws {
        for theme in Theme.AppearanceTheme.allCases {
            try roundTrip(theme)
        }
        for density in Theme.DensityMode.allCases {
            try roundTrip(density)
        }
        for family in Theme.FontFamily.allCases {
            try roundTrip(family)
        }
        for style in Theme.FloatingCornerStyle.allCases {
            try roundTrip(style)
        }
    }

    private func roundTrip<T: Codable & Equatable>(_ value: T) throws {
        let data = try JSONEncoder().encode(value)
        #expect(try JSONDecoder().decode(T.self, from: data) == value)
    }
}
