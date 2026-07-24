import SwiftUI
import AgentCore

/// Appearance tab: theme, density, font, corner style, scale, and the
/// opt-in usage/motion/silent-log toggles. Persists through
/// `EngineViewModel.updateAppearance`.
struct AppearanceSettingsTab: View {
    @Bindable var model: EngineViewModel

    @State private var theme: Theme.AppearanceTheme = .system
    @State private var density: Theme.DensityMode = .comfortable
    @State private var fontFamily: Theme.FontFamily = .rounded
    @State private var floatingCornerStyle: Theme.FloatingCornerStyle = .standard
    @State private var fontScale: Double = 1.0
    @State private var showUsage: Bool = false
    @State private var reduceMotion: Bool = false
    @State private var showSilentLog: Bool = false

    var body: some View {
        Form {
            Picker("Theme", selection: $theme) {
                Text("System").tag(Theme.AppearanceTheme.system)
                Text("Light").tag(Theme.AppearanceTheme.light)
                Text("Dark").tag(Theme.AppearanceTheme.dark)
            }
            .onChange(of: theme) { _, new in
                model.updateAppearance(.theme(new.rawValue))
            }

            Picker("Density", selection: $density) {
                Text("Comfortable").tag(Theme.DensityMode.comfortable)
                Text("Compact").tag(Theme.DensityMode.compact)
            }
            .onChange(of: density) { _, new in
                model.updateAppearance(.densityMode(new.rawValue))
            }

            Picker("Font", selection: $fontFamily) {
                ForEach(Theme.FontFamily.allCases) { family in
                    Text(family.displayName).tag(family)
                }
            }
            .onChange(of: fontFamily) { _, new in
                model.updateAppearance(.fontFamily(new.rawValue))
            }
            .accessibilityLabel("Font family for the sidebar, conversation, and diff panel")

            Picker("Popover corners", selection: $floatingCornerStyle) {
                ForEach(Theme.FloatingCornerStyle.allCases) { style in
                    Text(style.displayName).tag(style)
                }
            }
            .onChange(of: floatingCornerStyle) { _, new in
                model.updateAppearance(.floatingCornerStyle(new.rawValue))
            }
            .accessibilityLabel("Corner radius for popovers, palettes, and dropdown panels")

            HStack {
                Text("Font scale")
                Slider(value: $fontScale, in: 0.8...1.4, step: 0.1)
                Text("\(Int(fontScale * 100))%").monospacedDigit()
            }
            .onChange(of: fontScale) { _, new in
                model.updateAppearance(.fontSizeScale(new))
            }

            Toggle("Show token usage chip", isOn: $showUsage)
                .onChange(of: showUsage) { _, new in
                    model.updateAppearance(.showUsageChip(new))
                }

            Toggle("Reduce motion", isOn: $reduceMotion)
                .onChange(of: reduceMotion) { _, new in
                    model.updateAppearance(.reduceMotion(new))
                }

            Toggle("Show silent recovery log", isOn: $showSilentLog)
                .onChange(of: showSilentLog) { _, new in
                    model.updateAppearance(.showSilentRecoveryLog(new))
                }
        }
        .formStyle(.grouped)
        .task {
            theme = model.appearancePrefs.theme
            density = model.appearancePrefs.densityMode
            fontFamily = model.appearancePrefs.fontFamily
            floatingCornerStyle = model.appearancePrefs.floatingCornerStyle
            fontScale = model.appearancePrefs.fontSizeScale
            showUsage = model.appearancePrefs.showUsageChip
            reduceMotion = model.appearancePrefs.reduceMotion
            showSilentLog = model.appearancePrefs.showSilentRecoveryLog
        }
    }
}
