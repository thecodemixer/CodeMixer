import Foundation
import Testing
@testable import AgentCore
import AgentProtocol

@Suite("AppearancePrefs — keyed updates")
struct AppearancePrefsTests {

    @Test("Every AppearancePrefKey updates the matching stored field")
    func everyKeyUpdatesMatchingField() {
        var prefs = AppearancePrefs()

        prefs.update(.theme, .string("dark"))
        prefs.update(.codeTheme, .string("solarized"))
        prefs.update(.fontFamily, .string("serif"))
        prefs.update(.floatingCornerStyle, .string("sharp"))
        prefs.update(.fontSizeScale, .double(1.25))
        prefs.update(.showUsageChip, .bool(true))
        prefs.update(.reduceMotion, .bool(true))
        prefs.update(.densityMode, .string("compact"))

        #expect(prefs.theme == .dark)
        #expect(prefs.codeTheme == "solarized")
        #expect(prefs.fontFamily == .serif)
        #expect(prefs.floatingCornerStyle == .sharp)
        #expect(prefs.fontSizeScale == 1.25)
        #expect(prefs.showUsageChip == true)
        #expect(prefs.reduceMotion == true)
        #expect(prefs.densityMode == .compact)
    }

    @Test("Unknown enum raw values are ignored")
    func unknownEnumRawValuesAreIgnored() {
        var prefs = AppearancePrefs()
        prefs.update(.theme, .string("midnight"))
        prefs.update(.fontFamily, .string("comic"))
        prefs.update(.floatingCornerStyle, .string("blobby"))
        prefs.update(.densityMode, .string("spacious"))

        #expect(prefs.theme == .system)
        #expect(prefs.fontFamily == .rounded)
        #expect(prefs.floatingCornerStyle == .standard)
        #expect(prefs.densityMode == .comfortable)
    }

    @Test("Wrong value arm for a key is ignored")
    func wrongValueArmIsIgnored() {
        let original = AppearancePrefs(theme: .system,
                                       codeTheme: "default",
                                       fontFamily: .rounded,
                                       floatingCornerStyle: .standard,
                                       fontSizeScale: 1.0,
                                       showUsageChip: false,
                                       reduceMotion: false,
                                       densityMode: .comfortable)
        var prefs = original

        prefs.update(.theme, .bool(true))
        prefs.update(.codeTheme, .double(2.0))
        prefs.update(.fontFamily, .double(3.0))
        prefs.update(.floatingCornerStyle, .bool(true))
        prefs.update(.fontSizeScale, .string("large"))
        prefs.update(.showUsageChip, .string("yes"))
        prefs.update(.reduceMotion, .double(1.0))
        prefs.update(.densityMode, .bool(true))

        #expect(prefs == original)
    }

    @Test("Legacy string values decode into typed fields")
    func legacyStringValuesDecode() throws {
        let json = """
        {"theme":"dark","fontFamily":"serif","floatingCornerStyle":"sharp","densityMode":"compact"}
        """
        let prefs = try JSONDecoder().decode(AppearancePrefs.self, from: Data(json.utf8))
        #expect(prefs.theme == Theme.AppearanceTheme.dark)
        #expect(prefs.fontFamily == Theme.FontFamily.serif)
        #expect(prefs.floatingCornerStyle == Theme.FloatingCornerStyle.sharp)
        #expect(prefs.densityMode == Theme.DensityMode.compact)
    }
}
