import Foundation
import Testing
@testable import AgentCore
import AgentProtocol

@Suite("AppearancePrefs — patch updates")
struct AppearancePrefsTests {

    @Test("Every AppearancePrefPatch updates the matching stored field")
    func everyPatchUpdatesMatchingField() {
        var prefs = AppearancePrefs()

        prefs.update(.theme("dark"))
        prefs.update(.codeTheme("solarized"))
        prefs.update(.fontFamily("serif"))
        prefs.update(.floatingCornerStyle("sharp"))
        prefs.update(.fontSizeScale(1.25))
        prefs.update(.showUsageChip(true))
        prefs.update(.reduceMotion(true))
        prefs.update(.densityMode("compact"))
        prefs.update(.sidebarVisible(false))
        prefs.update(.showSilentRecoveryLog(true))

        #expect(prefs.theme == .dark)
        #expect(prefs.codeTheme == "solarized")
        #expect(prefs.fontFamily == .serif)
        #expect(prefs.floatingCornerStyle == .sharp)
        #expect(prefs.fontSizeScale == 1.25)
        #expect(prefs.showUsageChip == true)
        #expect(prefs.reduceMotion == true)
        #expect(prefs.densityMode == .compact)
        #expect(prefs.sidebarVisible == false)
        #expect(prefs.showSilentRecoveryLog == true)
    }

    @Test("Unknown enum raw values are ignored")
    func unknownEnumRawValuesAreIgnored() {
        var prefs = AppearancePrefs()
        prefs.update(.theme("midnight"))
        prefs.update(.fontFamily("comic"))
        prefs.update(.floatingCornerStyle("blobby"))
        prefs.update(.densityMode("spacious"))

        #expect(prefs.theme == .system)
        #expect(prefs.fontFamily == .rounded)
        #expect(prefs.floatingCornerStyle == .standard)
        #expect(prefs.densityMode == .comfortable)
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
