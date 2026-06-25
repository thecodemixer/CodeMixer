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
        prefs.update(.fontSizeScale, .double(1.25))
        prefs.update(.showUsageChip, .bool(true))
        prefs.update(.reduceMotion, .bool(true))
        prefs.update(.densityMode, .string("compact"))

        #expect(prefs.theme == "dark")
        #expect(prefs.codeTheme == "solarized")
        #expect(prefs.fontSizeScale == 1.25)
        #expect(prefs.showUsageChip == true)
        #expect(prefs.reduceMotion == true)
        #expect(prefs.densityMode == "compact")
    }

    @Test("Wrong value arm for a key is ignored")
    func wrongValueArmIsIgnored() {
        let original = AppearancePrefs(theme: "system",
                                       codeTheme: "default",
                                       fontSizeScale: 1.0,
                                       showUsageChip: false,
                                       reduceMotion: false,
                                       densityMode: "comfortable")
        var prefs = original

        prefs.update(.theme, .bool(true))
        prefs.update(.codeTheme, .double(2.0))
        prefs.update(.fontSizeScale, .string("large"))
        prefs.update(.showUsageChip, .string("yes"))
        prefs.update(.reduceMotion, .double(1.0))
        prefs.update(.densityMode, .bool(true))

        #expect(prefs == original)
    }
}
