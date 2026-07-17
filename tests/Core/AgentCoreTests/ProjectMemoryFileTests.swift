import Foundation
import Testing
import AgentTestSupport
@testable import AgentCore

@Suite("ProjectMemoryFile")
struct ProjectMemoryFileTests {

    @Test("Prefers CLAUDE.md when both memory files exist")
    func prefersClaudeMemoryFile() throws {
        let project = URL(fileURLWithPath: "/tmp/project-memory-claude")
        let fs = InMemoryFileSystem()
        try fs.writeAtomically(Data("claude memory".utf8), to: project.appendingPathComponent("CLAUDE.md"))
        try fs.writeAtomically(Data("agents memory".utf8), to: project.appendingPathComponent("AGENTS.md"))
        let memory = ProjectMemoryFile(fileSystem: fs)

        #expect(memory.present(in: project) == .claude)
        #expect(memory.presentFilename(in: project) == "CLAUDE.md")
        #expect(try memory.load(from: project)?.contents == "claude memory")
    }

    @Test("Returns AGENTS.md when only that memory file exists")
    func returnsAgentsMemoryFile() throws {
        let project = URL(fileURLWithPath: "/tmp/project-memory-agents")
        let fs = InMemoryFileSystem()
        try fs.writeAtomically(Data("agents memory".utf8), to: project.appendingPathComponent("AGENTS.md"))
        let memory = ProjectMemoryFile(fileSystem: fs)

        #expect(memory.present(in: project) == .agents)
        #expect(memory.exists(.agents, in: project))
        #expect(!memory.exists(.claude, in: project))
        #expect(try memory.load(from: project)?.kind == .agents)
    }

    @Test("Returns nil when no memory file exists")
    func returnsNilWithoutMemoryFile() throws {
        let project = URL(fileURLWithPath: "/tmp/project-memory-empty")
        let memory = ProjectMemoryFile(fileSystem: InMemoryFileSystem())

        #expect(memory.present(in: project) == nil)
        #expect(memory.presentFilename(in: project) == nil)
        #expect(try memory.load(from: project) == nil)
    }
}
