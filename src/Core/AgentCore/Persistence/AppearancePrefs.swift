import Foundation
import AgentProtocol

/// User-tunable appearance and behaviour preferences.
///
/// Persisted atomically through the `FileSystem` seam — never `UserDefaults`,
/// which the style guide forbids for application config (§20).
public struct AppearancePrefs: Sendable, Codable, Hashable {
    public var theme: String
    public var codeTheme: String
    public var fontSizeScale: Double
    public var showUsageChip: Bool
    public var reduceMotion: Bool
    public var densityMode: String
    /// Whether the session navigator rail is shown. GUI chrome, persisted here
    /// so it survives relaunch (never `UserDefaults`).
    public var sidebarVisible: Bool

    public init(theme: String = "system",
                codeTheme: String = "default",
                fontSizeScale: Double = 1.0,
                showUsageChip: Bool = false,
                reduceMotion: Bool = false,
                densityMode: String = "comfortable",
                sidebarVisible: Bool = true) {
        self.theme = theme
        self.codeTheme = codeTheme
        self.fontSizeScale = fontSizeScale
        self.showUsageChip = showUsageChip
        self.reduceMotion = reduceMotion
        self.densityMode = densityMode
        self.sidebarVisible = sidebarVisible
    }

    /// Tolerant decode so a `prefs.json` written by an older build (without a
    /// field added later, e.g. `sidebarVisible`) still loads with defaults
    /// instead of discarding every preference.
    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let defaults = AppearancePrefs()
        theme = try c.decodeIfPresent(String.self, forKey: .theme) ?? defaults.theme
        codeTheme = try c.decodeIfPresent(String.self, forKey: .codeTheme) ?? defaults.codeTheme
        fontSizeScale = try c.decodeIfPresent(Double.self, forKey: .fontSizeScale) ?? defaults.fontSizeScale
        showUsageChip = try c.decodeIfPresent(Bool.self, forKey: .showUsageChip) ?? defaults.showUsageChip
        reduceMotion = try c.decodeIfPresent(Bool.self, forKey: .reduceMotion) ?? defaults.reduceMotion
        densityMode = try c.decodeIfPresent(String.self, forKey: .densityMode) ?? defaults.densityMode
        sidebarVisible = try c.decodeIfPresent(Bool.self, forKey: .sidebarVisible) ?? defaults.sidebarVisible
    }

    public mutating func update(_ key: AppearancePrefKey, _ value: AppearancePrefValue) {
        switch (key, value) {
        case (.theme, .string(let v)):           theme = v
        case (.codeTheme, .string(let v)):       codeTheme = v
        case (.fontSizeScale, .double(let v)):   fontSizeScale = v
        case (.showUsageChip, .bool(let v)):     showUsageChip = v
        case (.reduceMotion, .bool(let v)):      reduceMotion = v
        case (.densityMode, .string(let v)):     densityMode = v
        case (.sidebarVisible, .bool(let v)):    sidebarVisible = v
        default:
            break
        }
    }
}
