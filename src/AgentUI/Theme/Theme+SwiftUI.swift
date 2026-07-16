import AgentCore
import SwiftUI

extension Theme {

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

    /// Motion vocabulary (visual-style §9). Every signature moment references
    /// exactly one of these named curves so timing reads as one grammar:
    /// things *arrive* gently, *leave* quickly, *change* in place, land with a
    /// *tactile* spring when the user acted directly, or take a *considered*
    /// beat for spatial transforms. Use `resolve(_:reduceMotion:)` at the call
    /// site so §1.14 (reduced motion) is honored from one place.
    public enum motion {
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

        public static let pulse: Animation = .easeInOut(duration: 0.85)
        public static let shimmer: Animation = .linear(duration: 1.2)
        public static let shimmerPhaseStep: Double = 0.6

        public static let quick: Animation = leaving
        public static let standard: Animation = .easeInOut(duration: 0.2)
        public static let gentle: Animation = changing

        public static func resolve(_ animation: Animation,
                                   reduceMotion: Bool) -> Animation? {
            reduceMotion ? nil : animation
        }
    }
}

extension Theme.FontFamily {
    public var design: Font.Design {
        switch self {
        case .system:  return .default
        case .rounded: return .rounded
        case .serif:   return .serif
        }
    }
}
