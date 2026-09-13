import Foundation
import AgentProtocol

struct ACPInitializeResult: Sendable, Equatable {
    let dashboardURL: URL?
    let dashboardTitle: String?
    let authMethodID: String?

    static func parse(_ value: JSONValue?) -> ACPInitializeResult {
        let meta = value?["_meta"]?.objectValue
            ?? value?["agentInfo"]?.objectValue?["_meta"]?.objectValue
        let dashboardURL = meta?[CodemixerACPKeys.dashboardUrl]?.stringValue
            .flatMap(URL.init(string:))
        let dashboardTitle = meta?[CodemixerACPKeys.dashboardTitle]?.stringValue
        let authMethodID = (value?["authMethods"]?.arrayValue ?? [])
            .compactMap { $0["id"]?.stringValue }
            .first

        return ACPInitializeResult(
            dashboardURL: dashboardURL,
            dashboardTitle: dashboardTitle,
            authMethodID: authMethodID
        )
    }
}
