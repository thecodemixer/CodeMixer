import Testing

@testable import AgentUI

@Suite("Custom agent executable paths survive being pasted from a shell")
struct CustomAgentExecutablePathTests {
    @Test("A plain absolute path is left untouched")
    func plainPathIsUnchanged() {
        #expect(CustomAgentInput.executablePath(from: "/usr/local/bin/agent") == "/usr/local/bin/agent")
    }

    @Test("Surrounding whitespace and newlines are trimmed")
    func surroundingWhitespaceIsTrimmed() {
        #expect(CustomAgentInput.executablePath(from: "  /usr/local/bin/agent\n") == "/usr/local/bin/agent")
    }

    @Test("A fully quoted path is unwrapped")
    func balancedQuotesAreUnwrapped() {
        #expect(CustomAgentInput.executablePath(from: "\"/usr/local/bin/agent\"") == "/usr/local/bin/agent")
        #expect(CustomAgentInput.executablePath(from: "'/usr/local/bin/agent'") == "/usr/local/bin/agent")
    }

    @Test("A stray leading quote from a half-selected paste is dropped")
    func unbalancedLeadingQuoteIsDropped() {
        #expect(CustomAgentInput.executablePath(from: "\"/usr/local/bin/agent") == "/usr/local/bin/agent")
    }

    @Test("Backslash-escaped spaces from Copy as Pathname are resolved")
    func escapedSpacesAreResolved() {
        #expect(CustomAgentInput.executablePath(from: "/My\\ Projects/bin/agent") == "/My Projects/bin/agent")
    }

    @Test("A quoted path keeps its real spaces")
    func quotedPathKeepsSpaces() {
        #expect(CustomAgentInput.executablePath(from: "\"/My Projects/bin/agent\"") == "/My Projects/bin/agent")
    }

    @Test("Single quotes preserve backslashes literally")
    func singleQuotesArePreservedLiterally() {
        #expect(CustomAgentInput.executablePath(from: "'/odd\\path/agent'") == "/odd\\path/agent")
    }

    @Test("An empty field stays empty so the sheet keeps Create disabled")
    func emptyStaysEmpty() {
        #expect(CustomAgentInput.executablePath(from: "   ").isEmpty)
        #expect(CustomAgentInput.executablePath(from: "\"").isEmpty)
    }
}

@Suite("Custom agent arguments split the way a shell would")
struct CustomAgentArgumentsTests {
    @Test("Whitespace separates bare tokens")
    func bareTokensSplitOnWhitespace() {
        #expect(CustomAgentInput.arguments(from: "acp --fake-agents") == ["acp", "--fake-agents"])
    }

    @Test("Runs of whitespace collapse and an empty line yields no arguments")
    func whitespaceRunsCollapse() {
        #expect(CustomAgentInput.arguments(from: "  acp\t\n --cwd ") == ["acp", "--cwd"])
        #expect(CustomAgentInput.arguments(from: "   ").isEmpty)
    }

    @Test("A quoted value containing spaces stays one argument")
    func quotedValueStaysOneArgument() {
        #expect(CustomAgentInput.arguments(from: "--cwd \"/My Projects/api\"")
            == ["--cwd", "/My Projects/api"])
        #expect(CustomAgentInput.arguments(from: "--cwd '/My Projects/api'")
            == ["--cwd", "/My Projects/api"])
    }

    @Test("Backslash-escaped spaces stay inside one argument")
    func escapedSpacesStayInOneArgument() {
        #expect(CustomAgentInput.arguments(from: "--cwd /My\\ Projects/api")
            == ["--cwd", "/My Projects/api"])
    }

    @Test("Quotes adjacent to text join into the surrounding token")
    func adjacentQuotesJoinTheToken() {
        #expect(CustomAgentInput.arguments(from: "--cwd=\"/My Projects\"") == ["--cwd=/My Projects"])
    }

    @Test("An explicitly empty quoted argument is preserved")
    func emptyQuotedArgumentIsPreserved() {
        #expect(CustomAgentInput.arguments(from: "--label \"\" acp") == ["--label", "", "acp"])
    }

    @Test("Single quotes keep backslashes literal")
    func singleQuotesKeepBackslashes() {
        #expect(CustomAgentInput.arguments(from: "'a\\b'") == ["a\\b"])
    }
}
