import Testing
import AgentCore
@testable import AgentUI

@Suite("Project Info presentation mirrors New Project fields")
struct ProjectInfoPresentationTests {
    @Test("A Claude project shows Single agent + Agent")
    func claudeProject() {
        let info = ProjectInfoPresentation.make(
            displayName: "api",
            path: "/workspace/api",
            projectType: .claudeCode,
            preferFreshAgentProcess: false
        )
        #expect(info.projectName == "api")
        #expect(info.path == "/workspace/api")
        #expect(info.categoryLabel == "Single agent")
        #expect(info.detailRows == [
            .init(label: "Agent", value: "Claude Code"),
        ])
        #expect(info.preferFreshAgentProcess == false)
    }

    @Test("A mixed project shows its default agent")
    func mixedProject() {
        let info = ProjectInfoPresentation.make(
            displayName: "poly",
            path: "/workspace/poly",
            projectType: .mixed(defaultAgent: .codex),
            preferFreshAgentProcess: true
        )
        #expect(info.categoryLabel == "Mixed")
        #expect(info.detailRows == [
            .init(label: "Default agent for new chats", value: "Codex"),
        ])
        #expect(info.preferFreshAgentProcess == true)
    }

    @Test("A mixed project with no default agent says None")
    func mixedWithoutDefault() {
        let info = ProjectInfoPresentation.make(
            displayName: "poly",
            path: "/workspace/poly",
            projectType: .mixed(defaultAgent: nil),
            preferFreshAgentProcess: false
        )
        #expect(info.detailRows == [
            .init(label: "Default agent for new chats", value: "None"),
        ])
    }

    @Test("A folder project hides Advanced and shows folder view")
    func folderProject() {
        let info = ProjectInfoPresentation.make(
            displayName: "docs",
            path: "/workspace/docs",
            projectType: .folder(.docs),
            preferFreshAgentProcess: true
        )
        #expect(info.categoryLabel == "Folder")
        #expect(info.detailRows == [
            .init(label: "Folder view", value: "Docs"),
        ])
        #expect(info.preferFreshAgentProcess == nil)
    }

    @Test("A custom ACP project surfaces every launch field")
    func customProject() {
        let ref = CustomAgentRef(
            id: "migration",
            displayName: "Mixer",
            transport: .agentClientProtocol,
            executablePath: "/opt/migration-acp",
            arguments: ["acp", "--cwd", "/My Projects/api"]
        )
        let info = ProjectInfoPresentation.make(
            displayName: "MongoMixer",
            path: "/workspace/MongoMixer",
            projectType: .custom(ref),
            preferFreshAgentProcess: false
        )
        #expect(info.categoryLabel == "Custom")
        #expect(info.detailRows == [
            .init(label: "Display name", value: "Mixer"),
            .init(label: "Executable path", value: "/opt/migration-acp"),
            .init(label: "Arguments", value: "acp --cwd \"/My Projects/api\""),
            .init(label: "Transport", value: "Agent Client Protocol"),
        ])
        #expect(info.preferFreshAgentProcess == false)
    }

    @Test("Empty custom arguments render as an em dash")
    func emptyArguments() {
        #expect(ProjectInfoPresentation.displayArguments([]) == "—")
    }

    @Test("Transport labels match the New Project picker")
    func transportLabels() {
        #expect(ProjectInfoPresentation.transportLabel(.interactiveTerminal) == "Interactive terminal")
        #expect(ProjectInfoPresentation.transportLabel(.stdioJSONRPC) == "Stdio JSON-RPC")
        #expect(ProjectInfoPresentation.transportLabel(.agentClientProtocol) == "Agent Client Protocol")
    }

    @Test("ProjectTypeKind reverse-maps every ProjectType arm")
    func reverseKindMapping() {
        #expect(ProjectTypeKind.from(projectType: .claudeCode) == .builtIn(.claudeCode))
        #expect(ProjectTypeKind.from(projectType: .codex) == .builtIn(.codex))
        #expect(ProjectTypeKind.from(projectType: .cursorCLI) == .builtIn(.cursorCLI))
        #expect(ProjectTypeKind.from(projectType: .mixed(defaultAgent: .claudeCode)) == .mixed)
        #expect(ProjectTypeKind.from(projectType: .folder(.files)) == .folder(.files))
        let custom = CustomAgentRef(
            id: "x",
            displayName: "X",
            transport: .agentClientProtocol,
            executablePath: "/bin/x",
            arguments: []
        )
        #expect(ProjectTypeKind.from(projectType: .custom(custom)) == .custom)
    }
}
