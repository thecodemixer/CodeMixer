import Foundation
import AgentProtocol

/// User-tunable appearance and behaviour preferences.
///
/// Persisted atomically through the `FileSystem` seam — never `UserDefaults`,
/// which the style guide forbids for application config (§20).
public struct AppearancePrefs: Sendable, Codable, Hashable {
    public var theme: Theme.AppearanceTheme
    public var codeTheme: String
    public var fontFamily: Theme.FontFamily
    public var floatingCornerStyle: Theme.FloatingCornerStyle
    public var fontSizeScale: Double
    public var showUsageChip: Bool
    /// UI-only: disables SwiftUI motion. Does not change engine heartbeat or
    /// `noEventGap` escalation timing (see `ActivityTiming`).
    public var reduceMotion: Bool
    public var densityMode: Theme.DensityMode
    /// Whether the session navigator rail is shown. GUI chrome, persisted here
    /// so it survives relaunch (never `UserDefaults`).
    public var sidebarVisible: Bool
    /// Opt-in debug pane for `SilentDiagnostics` records (default off).
    public var showSilentRecoveryLog: Bool

    public init(theme: Theme.AppearanceTheme = .system,
                codeTheme: String = "default",
                fontFamily: Theme.FontFamily = .rounded,
                floatingCornerStyle: Theme.FloatingCornerStyle = .standard,
                fontSizeScale: Double = 1.0,
                showUsageChip: Bool = false,
                reduceMotion: Bool = false,
                densityMode: Theme.DensityMode = .comfortable,
                sidebarVisible: Bool = true,
                showSilentRecoveryLog: Bool = false) {
        self.theme = theme
        self.codeTheme = codeTheme
        self.fontFamily = fontFamily
        self.floatingCornerStyle = floatingCornerStyle
        self.fontSizeScale = fontSizeScale
        self.showUsageChip = showUsageChip
        self.reduceMotion = reduceMotion
        self.densityMode = densityMode
        self.sidebarVisible = sidebarVisible
        self.showSilentRecoveryLog = showSilentRecoveryLog
    }

    /// Tolerant decode so a `prefs.json` written by an older build (without a
    /// field added later, e.g. `sidebarVisible`) still loads with defaults
    /// instead of discarding every preference.
    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let defaults = AppearancePrefs()
        theme = Self.decodeEnum(Theme.AppearanceTheme.self,
                                from: c,
                                forKey: CodingKeys.theme,
                                default: defaults.theme)
        codeTheme = try c.decodeIfPresent(String.self, forKey: .codeTheme) ?? defaults.codeTheme
        fontFamily = Self.decodeEnum(Theme.FontFamily.self,
                                     from: c,
                                     forKey: CodingKeys.fontFamily,
                                     default: defaults.fontFamily)
        floatingCornerStyle = Self.decodeEnum(Theme.FloatingCornerStyle.self,
                                              from: c,
                                              forKey: CodingKeys.floatingCornerStyle,
                                              default: defaults.floatingCornerStyle)
        fontSizeScale = try c.decodeIfPresent(Double.self, forKey: .fontSizeScale) ?? defaults.fontSizeScale
        showUsageChip = try c.decodeIfPresent(Bool.self, forKey: .showUsageChip) ?? defaults.showUsageChip
        reduceMotion = try c.decodeIfPresent(Bool.self, forKey: .reduceMotion) ?? defaults.reduceMotion
        densityMode = Self.decodeEnum(Theme.DensityMode.self,
                                      from: c,
                                      forKey: CodingKeys.densityMode,
                                      default: defaults.densityMode)
        sidebarVisible = try c.decodeIfPresent(Bool.self, forKey: .sidebarVisible) ?? defaults.sidebarVisible
        showSilentRecoveryLog = try c.decodeIfPresent(Bool.self, forKey: .showSilentRecoveryLog) ?? defaults.showSilentRecoveryLog
    }

    private enum CodingKeys: String, CodingKey {
        case theme, codeTheme, fontFamily, floatingCornerStyle, fontSizeScale
        case showUsageChip, reduceMotion, densityMode, sidebarVisible, showSilentRecoveryLog
    }

    public mutating func update(_ patch: AppearancePrefPatch) {
        switch patch {
        case .theme(let v):
            theme = Theme.AppearanceTheme(rawValue: v) ?? theme
        case .codeTheme(let v):
            codeTheme = v
        case .fontFamily(let v):
            fontFamily = Theme.FontFamily(rawValue: v) ?? fontFamily
        case .floatingCornerStyle(let v):
            floatingCornerStyle = Theme.FloatingCornerStyle(rawValue: v) ?? floatingCornerStyle
        case .fontSizeScale(let v):
            fontSizeScale = v
        case .showUsageChip(let v):
            showUsageChip = v
        case .reduceMotion(let v):
            reduceMotion = v
        case .densityMode(let v):
            densityMode = Theme.DensityMode(rawValue: v) ?? densityMode
        case .sidebarVisible(let v):
            sidebarVisible = v
        case .showSilentRecoveryLog(let v):
            showSilentRecoveryLog = v
        }
    }

    private static func decodeEnum<T: RawRepresentable>(
        _ type: T.Type,
        from container: KeyedDecodingContainer<CodingKeys>,
        forKey key: CodingKeys,
        default defaultValue: T
    ) -> T where T.RawValue == String {
        guard let raw = try? container.decodeIfPresent(String.self, forKey: key) else {
            return defaultValue
        }
        return T(rawValue: raw) ?? defaultValue
    }
}
