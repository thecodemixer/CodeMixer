/// Owns CodeMixer's namespaced ACP extension keys. This lowercase wire
/// namespace is intentionally distinct from `AppIdentity.bundleIdentifier`,
/// whose capitalization is part of the macOS application identity.
public enum CodemixerACPKeys {
    /// Lowercase reverse-DNS prefix reserved for CodeMixer ACP extensions.
    public static let reverseDNS = "com.codecave.codemixer"

    /// Client capability advertising A2UI support.
    public static let a2ui = "\(reverseDNS)/a2ui"

    /// Client capability allowing reverse `session/new` requests.
    public static let sessionNew = "\(reverseDNS)/sessionNew"

    /// Session update carrying a pipeline phase transition.
    public static let phaseUpdate = "\(reverseDNS)/phase_update"

    /// Session metadata identifying the project overview session.
    public static let overviewSession = "\(reverseDNS)/overviewSession"

    /// Agent metadata advertising the overview dashboard URL.
    public static let dashboardUrl = "\(reverseDNS)/dashboardUrl"

    /// Agent metadata advertising the overview dashboard title.
    public static let dashboardTitle = "\(reverseDNS)/dashboardTitle"
}
