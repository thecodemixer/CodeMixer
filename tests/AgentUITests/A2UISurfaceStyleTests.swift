import AgentCore
import AgentProtocol
import SwiftUI
import Testing
@testable import AgentUI

@Suite("A2UI surface style")
@MainActor
struct A2UISurfaceStyleTests {
    @Test("a Row's default cross-axis alignment tops its columns so their headers line up")
    func stretchAlignsToTop() {
        #expect(A2UISurfaceStyle.verticalAlignment(.stretch) == .top)
        #expect(A2UISurfaceStyle.verticalAlignment(.start) == .top)
        #expect(A2UISurfaceStyle.verticalAlignment(.center) == .center)
        #expect(A2UISurfaceStyle.verticalAlignment(.end) == .bottom)
    }

    @Test("text variants carry hierarchy, and only body copy gets extra leading")
    func textVariantsMapToHierarchy() {
        #expect(A2UISurfaceStyle.textStyle(for: .h3).font == Theme.typography.title)
        #expect(A2UISurfaceStyle.textStyle(for: .h5).font == Theme.typography.label)
        #expect(A2UISurfaceStyle.textStyle(for: .caption).font == Theme.typography.caption)
        #expect(A2UISurfaceStyle.textStyle(for: .body).lineSpacing > 0)
        #expect(A2UISurfaceStyle.textStyle(for: .h3).lineSpacing == 0)
        #expect(A2UISurfaceStyle.textStyle(for: .caption).lineSpacing == 0)
    }

    @Test("status icons keep their signal color, other catalog icons stay neutral")
    func statusIconsAreTinted() {
        #expect(A2UISurfaceStyle.iconTint(forCatalogIcon: "error") == Theme.signal.danger)
        #expect(A2UISurfaceStyle.iconTint(forCatalogIcon: "warning") == Theme.signal.warning)
        #expect(A2UISurfaceStyle.iconTint(forCatalogIcon: "info") == Theme.signal.info)
        #expect(A2UISurfaceStyle.iconTint(forCatalogIcon: "check") == Theme.signal.success)
        #expect(A2UISurfaceStyle.iconTint(forCatalogIcon: "folder") == Theme.text.secondary)
    }
}
