import A2UICore
import AgentProtocol
import SwiftUI

/// Presentation mappings from A2UI Basic Catalog vocabulary to SwiftUI /
/// SF Symbols. Pure lookup tables, kept out of `A2UISurfaceView` so the
/// renderer file stays about layout.
enum A2UISurfaceStyle {
    static func horizontalAlignment(_ align: A2UICrossAxisAlign) -> HorizontalAlignment {
        switch align {
        case .start: return .leading
        case .end: return .trailing
        case .center: return .center
        case .stretch: return .leading
        }
    }

    static func verticalAlignment(_ align: A2UICrossAxisAlign) -> VerticalAlignment {
        switch align {
        case .start: return .top
        case .end: return .bottom
        case .center: return .center
        case .stretch: return .center
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
