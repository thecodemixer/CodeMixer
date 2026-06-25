import Foundation
import Testing
@testable import AgentCore

@Suite("ResolvedEnvironment — PATH and variable helpers")
struct ResolvedEnvironmentTests {

    @Test("PATH falls back to the system-safe default when unset")
    func pathFallsBackWhenUnset() {
        let env = ResolvedEnvironment(variables: [:], shell: URL(fileURLWithPath: "/bin/zsh"))
        #expect(env.path == "/usr/bin:/bin:/usr/sbin:/sbin")
    }

    @Test("PATH uses the captured value when present")
    func pathUsesCapturedValue() {
        let env = ResolvedEnvironment(variables: ["PATH": "/custom/bin"], shell: URL(fileURLWithPath: "/bin/zsh"))
        #expect(env.path == "/custom/bin")
    }

    @Test("variable returns hits and nil for missing values")
    func variableLookup() {
        let env = ResolvedEnvironment(variables: ["HOME": "/Users/test"], shell: URL(fileURLWithPath: "/bin/zsh"))
        #expect(env.variable("HOME") == "/Users/test")
        #expect(env.variable("MISSING") == nil)
    }

    @Test("withOverrides adds and replaces variables without mutating the original")
    func withOverridesMergesVariables() {
        let env = ResolvedEnvironment(
            variables: ["PATH": "/usr/bin", "TERM": "xterm"],
            shell: URL(fileURLWithPath: "/bin/zsh")
        )

        let merged = env.withOverrides(["PATH": "/opt/bin", "FORCE_COLOR": "1"])

        #expect(merged["PATH"] == "/opt/bin")
        #expect(merged["TERM"] == "xterm")
        #expect(merged["FORCE_COLOR"] == "1")
        #expect(env.path == "/usr/bin")
    }

    @Test("ResolvedEnvironment equality includes variables, path-derived variables, and shell")
    func equalityUsesStoredValues() {
        let lhs = ResolvedEnvironment(variables: ["PATH": "/bin"], shell: URL(fileURLWithPath: "/bin/zsh"))
        let same = ResolvedEnvironment(variables: ["PATH": "/bin"], shell: URL(fileURLWithPath: "/bin/zsh"))
        let differentShell = ResolvedEnvironment(variables: ["PATH": "/bin"], shell: URL(fileURLWithPath: "/bin/bash"))
        let differentVariables = ResolvedEnvironment(variables: ["PATH": "/usr/bin"], shell: URL(fileURLWithPath: "/bin/zsh"))

        #expect(lhs == same)
        #expect(lhs != differentShell)
        #expect(lhs != differentVariables)
    }
}
