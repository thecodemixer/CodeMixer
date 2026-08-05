import Foundation

/// Pinned provenance and normative constants for CodeMixer's A2UI v0.9.1
/// compatibility profile.
///
/// CodeMixer does not execute the vendored JSON Schema files with a generic
/// Draft 2020-12 engine. Instead `A2UICore` implements a hand-written,
/// behavior-matched structural validator against the exact shapes recorded
/// here (see `A2UICatalog`). This is a deliberate scope decision: the
/// upstream schemas are the source of truth for what CodeMixer's validator
/// must accept/reject, but they are not interpreted at runtime.
///
/// Every source file below was vendored from one immutable upstream commit.
/// Re-pinning requires updating `schemaManifest` (URL + commit + SHA-256) in
/// the same change as any behavior update to `A2UICatalog` / `A2UIValidator`.
public enum A2UISchemaProfile {

    /// The A2UI protocol version CodeMixer emits on every server_to_client
    /// message it decodes attribution for, and the client_to_server messages
    /// it sends.
    public static let version = "v0.9.1"

    /// Versions CodeMixer's decoder accepts on inbound messages. `v1`-only
    /// fields/messages (e.g. `actionResponse`, action acknowledgement ids)
    /// are explicitly rejected — see `docs/architecture.md` A2UI section.
    public static let supportedVersions: Set<String> = ["v0.9", "v0.9.1"]

    /// Exact MIME type that activates the A2UI decoder on an ACP
    /// `EmbeddedResource`. The `uri` field is an opaque, stable identifier
    /// (used only for accumulator keying) and is never a security boundary.
    public static let embeddedResourceMIMEType = "application/a2ui+json"

    /// Official Basic Catalog id (schema-backed v0.9 id; v0.9.1 has no
    /// separate alias in the pinned schemas, so both capability keys below
    /// advertise the same id per the spec's per-version capability shape).
    public static let basicCatalogID = "https://a2ui.org/specification/v0_9/catalogs/basic/catalog.json"

    /// Test-only catalog id used by digital twins / fixtures while the
    /// production Basic Catalog gate (§5 of the plan) has not yet passed.
    /// Never advertised outside test builds.
    public static let testScopedCatalogID = "com.codecave.codemixer.test/basic-catalog-v0_9_1"

    /// Namespaced `_meta` key CodeMixer emits for its ACP capability
    /// advertisement. `_meta.a2ui` is accepted as an inbound compatibility
    /// alias (some early Custom ACP servers used the bare key) but CodeMixer
    /// never emits the alias itself.
    public static let clientCapabilitiesMetaKey = "com.codecave.codemixer/a2ui"
    public static let clientCapabilitiesMetaKeyAlias = "a2ui"

    /// A2A/ACP metadata key servers read client-owned surface data models
    /// from (`client_data_model.json`).
    public static let clientDataModelMetaKey = "a2uiClientDataModel"

    public struct SchemaSource: Sendable, Hashable {
        public let name: String
        public let sourceURL: String
        public let sha256: String

        public init(name: String, sourceURL: String, sha256: String) {
            self.name = name
            self.sourceURL = sourceURL
            self.sha256 = sha256
        }
    }

    /// Upstream commit every file in `schemaManifest` was vendored from.
    public static let upstreamCommit = "706ed4d0f2e33b8e42770445a51bd11376e6dbf4"
    public static let upstreamRepository = "https://github.com/a2ui-project/a2ui"
    public static let upstreamLicenseNote =
        "See LICENSE at the upstream repository root for terms; CodeMixer vendors schema text for reference/manifest purposes only and ships no upstream code."

    /// SHA-256 of each pinned file as vendored at `upstreamCommit`, computed
    /// from `raw.githubusercontent.com/a2ui-project/a2ui/<commit>/specification/v0_9_1/...`.
    /// A mismatch on re-vendor means the upstream file changed underneath us
    /// and `A2UICatalog` / `A2UIValidator` must be re-audited before bumping
    /// this manifest.
    public static let schemaManifest: [SchemaSource] = [.init(name: "docs/a2ui_protocol.md",
                                                              sourceURL: "specification/v0_9_1/docs/a2ui_protocol.md",
                                                              sha256: "c77afdf9a86f0b7feb79302566eb526a95f789ba6ecdcdfef6b26952db555ceb"),
                                                        .init(name: "catalogs/basic/catalog.json",
                                                              sourceURL: "specification/v0_9_1/catalogs/basic/catalog.json",
                                                              sha256: "4c694b68ee51e0e5716add4bcfddafb6311089df07314832f27decaca319c0d3"),
                                                        .init(name: "json/server_to_client.json",
                                                              sourceURL: "specification/v0_9_1/json/server_to_client.json",
                                                              sha256: "2ba29dbcb57611225c96d3e064d05cf97e9d8224b293c8b20d37b93922a2d30d"),
                                                        .init(name: "json/client_to_server.json",
                                                              sourceURL: "specification/v0_9_1/json/client_to_server.json",
                                                              sha256: "f049f8a554296a603cd3c1cef37dd6811006dc90e3ff52ce845d1674cd00a6b7"),
                                                        .init(name: "json/common_types.json",
                                                              sourceURL: "specification/v0_9_1/json/common_types.json",
                                                              sha256: "ac79788e95e5bdf0a39808953593a53c1bc9fcdcdb55480f4610613c6591e94c"),
                                                        .init(name: "json/client_capabilities.json",
                                                              sourceURL: "specification/v0_9_1/json/client_capabilities.json",
                                                              sha256: "917ff302b883c8c50475f0fafa836c17620078e7e2089392b322dc5df01de78f"),
                                                        .init(name: "json/server_capabilities.json",
                                                              sourceURL: "specification/v0_9_1/json/server_capabilities.json",
                                                              sha256: "bdaf275dd2abf279e62637ead1b840744e031d94735ec4f63d0c7c2fe5347dd4"),
                                                        .init(name: "json/client_data_model.json",
                                                              sourceURL: "specification/v0_9_1/json/client_data_model.json",
                                                              sha256: "6aefe455be9287caaf2f964ae480e8cf87706718106130908b41df19d5e982be")]
}
