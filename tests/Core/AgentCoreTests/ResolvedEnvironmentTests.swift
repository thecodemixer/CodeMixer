import Foundation
import Testing
import AgentTestSupport
@testable import AgentCore

@Suite("ResolvedEnvironment — PATH and variable helpers")
struct ResolvedEnvironmentTests {

    @Test("PATH falls back to the system-safe default when unset")
    func pathFallsBackWhenUnset() {
        let env = ResolvedEnvironment(variables: [:], shell: SystemPaths.zsh)
        #expect(env.path == "/usr/bin:/bin:/usr/sbin:/sbin")
    }

    @Test("PATH uses the captured value when present")
    func pathUsesCapturedValue() {
        let env = ResolvedEnvironment(variables: ["PATH": "/custom/bin"], shell: SystemPaths.zsh)
        #expect(env.path == "/custom/bin")
    }

    @Test("variable returns hits and nil for missing values")
    func variableLookup() {
        let env = ResolvedEnvironment(variables: ["HOME": TestPaths.fakeHome.path], shell: SystemPaths.zsh)
        #expect(env.variable("HOME") == TestPaths.fakeHome.path)
        #expect(env.variable("MISSING") == nil)
    }

    @Test("withOverrides adds and replaces variables without mutating the original")
    func withOverridesMergesVariables() {
        let env = ResolvedEnvironment(
            variables: ["PATH": "/usr/bin", "TERM": "xterm"],
            shell: SystemPaths.zsh
        )

        let merged = env.withOverrides(["PATH": "/opt/bin", "FORCE_COLOR": "1"])

        #expect(merged["PATH"] == "/opt/bin")
        #expect(merged["TERM"] == "xterm")
        #expect(merged["FORCE_COLOR"] == "1")
        #expect(env.path == "/usr/bin")
    }

    @Test("ptySpawnEnvironment strips billing-poison keys before PTY spawn")
    func ptySpawnEnvironmentStripsBillingPoisonKeys() {
        let env = ResolvedEnvironment(
            variables: [
                "PATH": "/usr/bin",
                "CLAUDE_CODE_ENTRYPOINT": "sdk",
                "ANTHROPIC_API_KEY": "sk-test",
                "HOME": TestPaths.fakeHome.path,
            ],
            shell: SystemPaths.zsh
        )

        let spawn = env.ptySpawnEnvironment(adapterOverrides: [
            "TERM": "xterm-256color",
            "ANTHROPIC_API_KEY": "should-not-win",
        ])

        #expect(spawn["PATH"] == "/usr/bin")
        #expect(spawn["HOME"] == TestPaths.fakeHome.path)
        #expect(spawn["TERM"] == "xterm-256color")
        #expect(spawn["CLAUDE_CODE_ENTRYPOINT"] == nil)
        #expect(spawn["ANTHROPIC_API_KEY"] == nil)
    }

    @Test("ResolvedEnvironment equality includes variables, path-derived variables, and shell")
    func equalityUsesStoredValues() {
        let lhs = ResolvedEnvironment(variables: ["PATH": "/bin"], shell: SystemPaths.zsh)
        let same = ResolvedEnvironment(variables: ["PATH": "/bin"], shell: SystemPaths.zsh)
        let differentShell = ResolvedEnvironment(variables: ["PATH": "/bin"], shell: URL(fileURLWithPath: "/bin/bash"))
        let differentVariables = ResolvedEnvironment(variables: ["PATH": "/usr/bin"], shell: SystemPaths.zsh)

        #expect(lhs == same)
        #expect(lhs != differentShell)
        #expect(lhs != differentVariables)
    }
}
