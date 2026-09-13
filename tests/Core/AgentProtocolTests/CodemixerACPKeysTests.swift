import AgentProtocol
import Testing

@Suite("CodeMixer ACP extension keys")
struct CodemixerACPKeysTests {
    @Test("all keys use the lowercase CodeMixer reverse-DNS namespace")
    func exactValues() {
        #expect(CodemixerACPKeys.reverseDNS == "com.codecave.codemixer")
        #expect(CodemixerACPKeys.a2ui == "com.codecave.codemixer/a2ui")
        #expect(CodemixerACPKeys.sessionNew == "com.codecave.codemixer/sessionNew")
        #expect(CodemixerACPKeys.phaseUpdate == "com.codecave.codemixer/phase_update")
        #expect(CodemixerACPKeys.overviewSession == "com.codecave.codemixer/overviewSession")
        #expect(CodemixerACPKeys.dashboardUrl == "com.codecave.codemixer/dashboardUrl")
        #expect(CodemixerACPKeys.dashboardTitle == "com.codecave.codemixer/dashboardTitle")
    }
}
