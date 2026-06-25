import Testing
@testable import AgentUI

@Suite("QRCodeRenderer")
struct QRCodeRendererTests {

    @Test("renders pairing URLs into an image")
    func rendersPairingURL() {
        let image = QRCodeRenderer().image(for: "codemixer://pair?host=127.0.0.1&port=8421")
        #expect(image != nil)
    }
}
