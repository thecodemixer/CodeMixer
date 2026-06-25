<!--
CODEOWNERS template.

Copy the block below to `.github/CODEOWNERS` (or `CODEOWNERS` at repo root, or `docs/CODEOWNERS`).
GitHub auto-discovers the file in any of these locations.

Replace `@org/team` and `@user` placeholders.
-->

# CODEOWNERS — review assignment by path
#
# Syntax: <path pattern> <owner1> <owner2>...
# Owners can be GitHub usernames (@user), team slugs (@org/team), or email addresses.
# Later patterns override earlier ones; specificity wins.
# Lines starting with `#` are comments. Blank lines are ignored.

# ─── Default owner for everything ─────────────────────────────────────────────
*                                       @{org}/maintainers

# ─── Core engine ──────────────────────────────────────────────────────────────
src/Core/AgentCore/**           @{org}/engine-team
src/Core/CPosixBridge/**        @{org}/engine-team @{org}/security
src/Core/AgentProtocol/**       @{org}/engine-team @{org}/api-team
tests/Core/AgentCoreTests/**    @{org}/engine-team
tests/Core/AgentProtocolTests/** @{org}/engine-team @{org}/api-team

# ─── Adapters ─────────────────────────────────────────────────────────────────
src/AgenticCLIs/**            @{org}/adapter-team
src/AgentAdapterAPI/**     @{org}/adapter-team @{org}/engine-team
tests/AgenticCLIs/ClaudeCode/ClaudeAdapterTests/** @{org}/adapter-team
tests/AgenticCLIs/ClaudeCode/ClaudeCodeTwinTests/** @{org}/adapter-team

# ─── Remote control + daemon ──────────────────────────────────────────────────
src/Remote/AgentRemoteControl/**  @{org}/api-team @{org}/security
tests/Remote/AgentRemoteControlTests/** @{org}/api-team
tests/Remote/RemoteParityTests/** @{org}/api-team @{org}/engine-team
src/Remote/CodemixerDaemon/**                                          @{org}/api-team

# ─── UI ───────────────────────────────────────────────────────────────────────
src/AgentUI/**             @{org}/ui-team
tests/AgentUITests/**      @{org}/ui-team
tests/TestSupport/AgentTestSupportTests/** @{org}/engine-team
src/CodemixerApp/Codemixer.xcodeproj/**                                @{org}/ui-team

# ─── Docs ─────────────────────────────────────────────────────────────────────
docs/**                                 @{org}/maintainers
docs/code-style.md                      @{org}/maintainers @{org}/style-council
docs/visual-style.md                    @{org}/ui-team @{org}/style-council
docs/architecture.md                    @{org}/engine-team @{org}/maintainers
docs/reference/**                       @{org}/maintainers

# ─── CI, tooling, and meta ────────────────────────────────────────────────────
.github/**                              @{org}/maintainers
.swiftformat                            @{org}/maintainers
.swiftlint.yml                          @{org}/maintainers
Makefile                                @{org}/maintainers
scripts/**                              @{org}/maintainers
CODEOWNERS                              @{org}/maintainers

# ─── Security-sensitive files ─────────────────────────────────────────────────
SECURITY.md                             @{org}/security @{org}/maintainers
**/Pairing*.swift                       @{org}/security @{org}/api-team
**/Keychain*.swift                      @{org}/security

# ─── Generated / vendored (block direct edits except by maintainers) ──────────
**/*.generated.swift                    @{org}/maintainers
Vendored/**                             @{org}/maintainers
