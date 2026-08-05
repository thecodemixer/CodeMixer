import Foundation

/// Named hard limits enforced before decode and evaluation. Every limit is a
/// concrete constant (never a magic number at the call site) so a reviewer
/// can see the whole safety budget in one place.
public enum A2UILimits {
    /// Maximum bytes for one accumulated ACP `EmbeddedResource` payload
    /// before it is rejected without attempting to parse it.
    public static let maxPayloadBytes = 2 * 1024 * 1024

    /// Maximum number of top-level messages in one decoded batch.
    public static let maxBatchItems = 256

    /// Maximum JSON nesting depth accepted while decoding a component tree
    /// or data model value.
    public static let maxJSONDepth = 64

    /// Maximum total JSON scalar/collection nodes in one decoded value.
    public static let maxJSONNodes = 20_000

    /// Maximum live surfaces per session.
    public static let maxSurfacesPerSession = 64

    /// Maximum components per surface (cumulative across `updateComponents`).
    public static let maxComponentsPerSurface = 2_000

    /// Maximum items a repeated-list `ChildList` template may expand to.
    public static let maxListExpansion = 500

    /// Maximum recursion depth while resolving nested `FunctionCall`/
    /// `DataBinding` expressions.
    public static let maxExpressionDepth = 32

    /// Maximum number of function calls evaluated while resolving one
    /// dynamic value (guards against expression graphs designed to explode
    /// evaluation cost without deep nesting).
    public static let maxExpressionCallCount = 256

    /// Maximum length of one JSON Pointer string.
    public static let maxPointerLength = 512

    /// Maximum length of a `regex`/`validationRegexp` pattern string, and the
    /// maximum input length matched against it — guards against ReDoS.
    public static let maxRegexPatternLength = 256
    public static let maxRegexInputLength = 10_000

    /// Maximum length of a `formatDate` TR35 pattern / `formatString`
    /// interpolation template.
    public static let maxFormatPatternLength = 256

    /// Maximum resolved text/string length for any single dynamic value.
    public static let maxResolvedStringLength = 100_000

    /// Update-frequency guard: minimum spacing between `updateDataModel`
    /// coalescable writes to the same path before the reducer coalesces
    /// instead of applying every intermediate value.
    public static let minDataModelUpdateInterval: Duration = .milliseconds(16)
}
