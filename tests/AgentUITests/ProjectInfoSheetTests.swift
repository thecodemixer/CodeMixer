import Testing
import AgentCore
@testable import AgentUI

@Suite("Project Info sheet reads the registered project, not defaults")
struct ProjectInfoSheetTests {
    @Test("The sheet's project drives every displayed field")
    @MainActor
    func sheetMirrorsRegisteredProject() {
        let project = WorkspaceProjectsStore.ProjectRef(
            path: "/workspace/api",
            displayName: "api",
            projectType: .claudeCode,
            preferFreshAgentProcess: true,
            workingDirectoryPath: "/src/api"
        )
        var closed = false
        let sheet = ProjectInfoSheet(project: project) { closed = true }

        let info = ProjectInfoPresentation.make(from: sheet.project)
        #expect(info.projectName == "api")
        #expect(info.path == "/workspace/api")
        #expect(info.workingDirectoryPath == "/src/api")
        #expect(info.categoryLabel == "Single agent")
        #expect(info.preferFreshAgentProcess == true)

        sheet.onClose()
        #expect(closed)
    }

    @Test("A folder project hides the agent-only Advanced row and working directory")
    @MainActor
    func folderProjectHasNoAdvancedRow() {
        let project = WorkspaceProjectsStore.ProjectRef(
            path: "/workspace/docs",
            displayName: "docs",
            projectType: .folder(.files),
            preferFreshAgentProcess: true,
            workingDirectoryPath: "/src/docs"
        )
        let sheet = ProjectInfoSheet(project: project) {}

        // `nil` is what makes the sheet's DisclosureGroup disappear, so a folder
        // project must not inherit the stored agent-process preference.
        let info = ProjectInfoPresentation.make(from: sheet.project)
        #expect(info.preferFreshAgentProcess == nil)
        #expect(info.workingDirectoryPath == nil)
        #expect(project.workingDirectoryPath == nil)
    }

    @Test("Agent projects expose the working directory even when it matches the project folder")
    @MainActor
    func agentProjectShowsDefaultWorkingDirectory() {
        let project = WorkspaceProjectsStore.ProjectRef(
            path: "/workspace/api",
            displayName: "api",
            projectType: .codex
        )
        let info = ProjectInfoPresentation.make(from: project)
        #expect(info.workingDirectoryPath == "/workspace/api")
    }
}
