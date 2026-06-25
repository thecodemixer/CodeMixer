import Foundation
import Testing
@testable import AgentCore
import AgentTestSupport

@Suite("ShellEnvironmentResolver — NUL parsing")
struct ShellEnvResolverTests {

    @Test("`env -0` output is parsed into key→value pairs")
    func parsesNULRecords() {
        let resolver = ShellEnvironmentResolver(environment: FakeEnvironment())
        let data = Data("PATH=/usr/bin:/bin\0HOME=/Users/h\0LC_ALL=en_US.UTF-8\0".utf8)
        let parsed = resolver.parseNULSeparatedEnv(data)
        #expect(parsed["PATH"] == "/usr/bin:/bin")
        #expect(parsed["HOME"] == "/Users/h")
        #expect(parsed["LC_ALL"] == "en_US.UTF-8")
    }

    @Test("Values containing '=' keep everything after the first equals")
    func valueWithEquals() {
        let resolver = ShellEnvironmentResolver(environment: FakeEnvironment())
        let data = Data("FOO=a=b=c\0".utf8)
        let parsed = resolver.parseNULSeparatedEnv(data)
        #expect(parsed["FOO"] == "a=b=c")
    }
}
