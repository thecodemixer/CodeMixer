import A2UICore
import AgentProtocol
import SwiftUI

/// Presentation mappings from A2UI Basic Catalog vocabulary to SwiftUI /
/// SF Symbols. Pure lookup tables, kept out of `A2UISurfaceView` so the
/// renderer file stays about layout.
enum A2UISurfaceStyle {
    struct TextStyle {
        let font: Font
        let color: Color
        /// Extra leading. Body copy in these cards is often a dense multi-line
        /// finding, which reads as a block without it; headings and captions are
        /// short, so extra leading there only loosens the hierarchy.
        let lineSpacing: CGFloat
    }

    /// Maps Basic Catalog text variants onto Theme tokens so titles/labels in
    /// review and plan cards read as hierarchy, not undifferentiated body copy.
    static func textStyle(for variant: A2UITextVariant?) -> TextStyle {
        switch variant {
        case .h1, .h2, .h3:
            return TextStyle(font: Theme.typography.title, color: Theme.text.primary, lineSpacing: 0)
        case .h4, .h5:
            return TextStyle(font: Theme.typography.label, color: Theme.text.primary, lineSpacing: 0)
        case .caption:
            return TextStyle(font: Theme.typography.caption, color: Theme.text.secondary, lineSpacing: 0)
        case .body, .none:
            return TextStyle(font: Theme.typography.body,
                             color: Theme.text.primary,
                             lineSpacing: Theme.spacing.s4 / 2)
        }
    }

    /// Status-carrying catalog icons keep their signal color. The catalog has no
    /// color property, so a uniformly secondary tint would throw away the one
    /// severity cue a caller can express — `error`/`warning`/`info` are the
    /// vocabulary emitters reach for when ranking items.
    static func iconTint(forCatalogIcon name: String) -> Color {
        switch name {
        case "error": return Theme.signal.danger
        case "warning": return Theme.signal.warning
        case "info": return Theme.signal.info
        case "check": return Theme.signal.success
        default: return Theme.text.secondary
        }
    }

    static func horizontalAlignment(_ align: A2UICrossAxisAlign) -> HorizontalAlignment {
        switch align {
        case .start: return .leading
        case .end: return .trailing
        case .center: return .center
        case .stretch: return .leading
        }
    }

    /// `stretch` is the Row default. Mapping it to `center` made side-by-side
    /// columns of unequal length float against each other — their headers no
    /// longer lined up, which is the first thing a reader scans. SwiftUI cannot
    /// literally stretch a child's height, so top is the honest equivalent.
    static func verticalAlignment(_ align: A2UICrossAxisAlign) -> VerticalAlignment {
        switch align {
        case .start, .stretch: return .top
        case .end: return .bottom
        case .center: return .center
        }
    }

    static func choiceGlyph(isMultiple: Bool, selected: Bool) -> String {
        if isMultiple { return selected ? "checkmark.square.fill" : "square" }
        return selected ? "largecircle.fill.circle" : "circle"
    }

    /// Best-effort mapping from the Basic Catalog's Material-style icon names
    /// to SF Symbols. Unmapped names fall back to a neutral placeholder glyph
    /// rather than failing to render — the catalog's icon vocabulary is open,
    /// so a miss is expected rather than exceptional.
    static func sfSymbol(forCatalogIcon name: String) -> String {
        catalogIconSymbols[name] ?? unmappedIconSymbol
    }

    private static let unmappedIconSymbol = "questionmark.circle"

    private static let catalogIconSymbols: [String: String] = [
        "accountCircle": "person.circle",
        "add": "plus",
        "arrowBack": "arrow.left",
        "arrowForward": "arrow.right",
        "attachFile": "paperclip",
        "calendarToday": "calendar",
        "call": "phone",
        "camera": "camera",
        "check": "checkmark",
        "close": "xmark",
        "delete": "trash",
        "download": "arrow.down.circle",
        "edit": "pencil",
        "error": "exclamationmark.triangle",
        "event": "calendar.badge.clock",
        "fastForward": "forward.fill",
        "favorite": "heart.fill",
        "favoriteOff": "heart",
        "folder": "folder",
        "help": "questionmark.circle",
        "home": "house",
        "info": "info.circle",
        "locationOn": "mappin.circle",
        "lock": "lock",
        "lockOpen": "lock.open",
        "mail": "envelope",
        "menu": "line.3.horizontal",
        "moreHoriz": "ellipsis",
        "moreVert": "ellipsis",
        "notifications": "bell",
        "notificationsOff": "bell.slash",
        "pause": "pause.fill",
        "payment": "creditcard",
        "person": "person",
        "phone": "phone",
        "play": "play.fill",
        "search": "magnifyingglass",
        "send": "paperplane",
        "settings": "gearshape",
        "share": "square.and.arrow.up",
        "shoppingCart": "cart",
        "star": "star.fill",
        "starOff": "star",
        "thumbDown": "hand.thumbsdown",
        "thumbUp": "hand.thumbsup",
        "warning": "exclamationmark.triangle",
    ]
}
