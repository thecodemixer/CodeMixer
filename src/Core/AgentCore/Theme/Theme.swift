import CoreGraphics
import Foundation

/// Headless visual tokens and appearance enums. SwiftUI colors, fonts, and
/// motion live in `AgentUI` as extensions on this namespace.
public enum Theme {

    // MARK: - Appearance preference enums

    public enum AppearanceTheme: String, CaseIterable, Sendable, Codable, Hashable {
        case system
        case light
        case dark
    }

    public enum DensityMode: String, CaseIterable, Sendable, Codable, Hashable {
        case comfortable
        case compact
    }

    /// User-selectable text personality. SwiftUI's `Font.Design` mapping lives
    /// in `AgentUI` so this module stays SwiftUI-free.
    public enum FontFamily: String, CaseIterable, Sendable, Codable, Hashable, Identifiable {
        case system
        case rounded
        case serif

        public var id: String { rawValue }

        public var displayName: String {
            switch self {
            case .system:  return "System"
            case .rounded: return "Rounded"
            case .serif:   return "Serif"
            }
        }
    }

    /// Corner personality for floating surfaces (popovers, palettes, dropdown
    /// panels). Applied app-wide via `CodemixerAppearanceModifier`.
    public enum FloatingCornerStyle: String, CaseIterable, Sendable, Codable, Hashable, Identifiable {
        case sharp
        case standard
        case soft

        public var id: String { rawValue }

        public var radius: CGFloat {
            switch self {
            case .sharp:    return Theme.corner.small
            case .standard: return Theme.corner.floating
            case .soft:     return Theme.corner.medium
            }
        }

        /// Composer bar dropdowns (mode/model) — half the floating radius.
        public var dropdownRadius: CGFloat { radius / 2 }

        public var displayName: String {
            switch self {
            case .sharp:    return "Sharp"
            case .standard: return "Standard"
            case .soft:     return "Soft"
            }
        }
    }

    // MARK: - Numeric tokens

    public enum spacing {
        public static let s4: CGFloat = 4
        public static let s8: CGFloat = 8
        public static let s12: CGFloat = 12
        public static let s16: CGFloat = 16
        public static let s24: CGFloat = 24
        public static let s32: CGFloat = 32
        public static let s48: CGFloat = 48
        public static let s64: CGFloat = 64
    }

    public enum corner {
        public static let hairline: CGFloat = 1
        public static let chip: CGFloat = 4
        public static let small: CGFloat = 6
        public static let medium: CGFloat = 10
        public static let large: CGFloat = 16
        /// Popovers, palettes, and dropdown panels — floating elevation
        /// (visual-style §10). Smaller than `large` so menus feel crisp.
        public static let floating: CGFloat = 8
        /// Composer bar dropdowns (mode/model) — half of `floating`.
        public static let dropdown: CGFloat = 4
    }

    public enum stroke {
        public static let hairline: CGFloat = 0.5
        public static let standard: CGFloat = 1
        public static let focus: CGFloat = 2
    }

    public enum opacity {
        public static let faint: Double = 0.08
        public static let subtle: Double = 0.10
        public static let quiet: Double = 0.12
        public static let muted: Double = 0.18
        public static let medium: Double = 0.40
        public static let divider: Double = 0.50
        public static let secondary: Double = 0.60
        public static let emphasized: Double = 0.70
        public static let waveformRange: Double = 0.30
        public static let pulseBase: Double = 0.35
        public static let pulseRange: Double = 0.65
    }

    public enum layout {
        public static let compactControlMinWidth: CGFloat = 200
        /// Model picker in the composer bottom bar.
        public static let composerModelPickerMinWidth: CGFloat = compactControlMinWidth * 1.4
        public static let commandPaletteMinWidth: CGFloat = 220
        public static let commandPaletteMaxWidth: CGFloat = 380
        public static let slashPaletteMinWidth: CGFloat = 280
        public static let slashPaletteMaxHeight: CGFloat = 240
        public static let attachmentPaletteMinWidth: CGFloat = 320
        public static let attachmentPaletteMaxWidth: CGFloat = 420
        public static let messageMaxWidth: CGFloat = 720
        public static let diffPanelMinWidth: CGFloat = 360
        public static let diffSidebarMinWidth: CGFloat = 200
        public static let diffSidebarIdealWidth: CGFloat = 240
        public static let diffSidebarMaxWidth: CGFloat = 320
        public static let installMinWidth: CGFloat = 480
        public static let installMaxWidth: CGFloat = 560
        public static let settingsMinWidth: CGFloat = 560
        public static let settingsMinHeight: CGFloat = 420
        public static let debugTerminalMinWidth: CGFloat = 720
        public static let debugTerminalMinHeight: CGFloat = 480
        public static let projectPickerMinWidth: CGFloat = 520
        public static let projectPickerMinHeight: CGFloat = 480
        public static let projectPickerMaxHeight: CGFloat = 320
        public static let authGateMinWidth: CGFloat = 540
        public static let authGateMinHeight: CGFloat = 360
        public static let authGateContentMaxWidth: CGFloat = 480
        public static let agentPickerMinWidth: CGFloat = 420
        public static let agentPickerMinHeight: CGFloat = 320
        public static let workspaceSidebarMinWidth: CGFloat = 480
        public static let sessionSidebarMinWidth: CGFloat = 220
        public static let sessionSidebarIdealWidth: CGFloat = 260
        public static let sessionSidebarMaxWidth: CGFloat = 360
        public static let sessionSidebarIconRailWidth: CGFloat = 52
        public static let globalPaletteWidth: CGFloat = 560
        public static let globalPaletteMaxHeight: CGFloat = 360
        public static let activityDotSize: CGFloat = 5
        public static let activityDotsHeight: CGFloat = 8
        public static let statusPillMaxWidth: CGFloat = 360
        public static let eventLogMinWidth: CGFloat = 600
        public static let eventLogMinHeight: CGFloat = 400
        public static let remoteSettingsMinHeight: CGFloat = 180
    }
}
