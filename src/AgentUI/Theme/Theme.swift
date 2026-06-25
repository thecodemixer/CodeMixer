import SwiftUI

/// All visual tokens for the serene UI. Views never reach for `Color.red` or
/// magic spacing numbers — they reach for `Theme.surface.bubble`,
/// `Theme.spacing.s16`, `Theme.typography.body`.
public enum Theme {

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

    public enum surface {
        public static let canvas       = Color(nsColor: .windowBackgroundColor)
        public static let panel        = Color(nsColor: .underPageBackgroundColor)
        public static let bubble       = Color(nsColor: .controlBackgroundColor).opacity(0.6)
        public static let bubbleUser   = Color.accentColor.opacity(0.12)
        public static let card         = Color(nsColor: .controlBackgroundColor)
        public static let divider      = Color(nsColor: .separatorColor).opacity(0.5)
        /// Recessed well for code blocks (visual-style §15). Adapts to
        /// light/dark via the system editor background.
        public static let sunken       = Color(nsColor: .textBackgroundColor)
    }

    public enum text {
        public static let primary      = Color.primary
        public static let secondary    = Color.secondary
        public static let tertiary     = Color(nsColor: .tertiaryLabelColor)
    }

    public enum signal {
        public static let warning      = Color.orange
        public static let danger       = Color.red
        public static let success      = Color.green
        public static let info         = Color.blue
    }

    public enum diff {
        public static let addition     = Color.green.opacity(0.18)
        public static let deletion     = Color.red.opacity(0.18)
        public static let context      = Color.clear
    }

    public enum typography {
        public static let title        = Font.system(.title2, design: .default, weight: .semibold)
        public static let body         = Font.system(.body, design: .default)
        public static let prose        = Font.system(.body, design: .serif)
        public static let mono         = Font.system(.body, design: .monospaced)
        public static let monoSmall    = Font.system(.callout, design: .monospaced)
        public static let label        = Font.system(.subheadline, design: .default, weight: .medium)
        public static let caption      = Font.system(.caption, design: .default)
        public static let iconSmall    = Font.system(size: 10, weight: .semibold)
        public static let iconMedium   = Font.system(size: 20)
        public static let iconLarge    = Font.system(size: 32, weight: .light)
        public static let emptyState   = Font.system(size: 44, weight: .light)
        public static let heroIcon     = Font.system(size: 56, weight: .light)
    }

    public enum corner {
        public static let hairline: CGFloat = 1
        public static let chip: CGFloat = 4
        public static let small: CGFloat = 6
        public static let medium: CGFloat = 10
        public static let large: CGFloat = 16
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

    /// Motion vocabulary (visual-style §9). Every signature moment references
    /// exactly one of these named curves so timing reads as one grammar:
    /// things *arrive* gently, *leave* quickly, *change* in place, land with a
    /// *tactile* spring when the user acted directly, or take a *considered*
    /// beat for spatial transforms. Use `resolve(_:reduceMotion:)` at the call
    /// site so §1.14 (reduced motion) is honored from one place.
    public enum motion {
        // Named vocabulary.
        /// New content settles into place (opacity + small offset).
        public static let arriving: Animation = .easeOut(duration: 0.32)
        /// Content departs — faster than it arrived so it never lingers.
        public static let leaving: Animation = .easeIn(duration: 0.12)
        /// A value changes in place (selection wash, width, cross-fade).
        public static let changing: Animation = .easeInOut(duration: 0.32)
        /// A larger spatial transform that deserves a beat (collapse-to-chip).
        public static let considered: Animation = .easeInOut(duration: 0.35)
        /// Direct manipulation feedback — a subtle spring.
        public static let tactile: Animation = .spring(response: 0.3, dampingFraction: 0.82)
        /// No animation. Used as the reduced-motion fallback.
        public static let instant: Animation = .linear(duration: 0)

        // Continuous ambient motion.
        public static let pulse: Animation = .easeInOut(duration: 0.85)
        public static let shimmer: Animation = .linear(duration: 1.2)
        public static let shimmerPhaseStep: Double = 0.6

        // Back-compat aliases (pre-vocabulary call sites).
        public static let quick: Animation = leaving
        public static let standard: Animation = .easeInOut(duration: 0.2)
        public static let gentle: Animation = changing

        /// The single reduced-motion seam. Returns `nil` (instant, no animation)
        /// when the user prefers reduced motion, otherwise the requested curve.
        /// Callers pair this with an opacity-only `transition` so the change is
        /// still legible without movement.
        public static func resolve(_ animation: Animation,
                                   reduceMotion: Bool) -> Animation? {
            reduceMotion ? nil : animation
        }
    }
}
