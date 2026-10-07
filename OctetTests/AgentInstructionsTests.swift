import XCTest

final class AgentInstructionsTests: XCTestCase {
    private func state(agents: String? = nil, claude: String? = nil, linked: Bool = false) -> AgentInstructions.State {
        AgentInstructions.state(of: .init(agents: agents, claude: claude, claudeLinksToAgents: linked))
    }

    func testWhichFilesThereAre() {
        XCTAssertEqual(state(), .none)
        XCTAssertEqual(state(agents: "  \n", claude: ""), .none)
        XCTAssertEqual(state(agents: "Use tabs."), .agentsOnly)
        XCTAssertEqual(state(claude: "Use tabs."), .claudeOnly)
        XCTAssertEqual(state(agents: "Use tabs.", claude: "Use spaces."), .split)
        XCTAssertEqual(state(agents: "Use tabs.", claude: "Use tabs."), .split)
        XCTAssertEqual(state(agents: "Use tabs.", claude: "@AGENTS.md\n"), .linked)
        XCTAssertEqual(state(agents: "Use tabs.", claude: "# Notes\n\n@./AGENTS.md\n\nMore."), .linked)
        XCTAssertEqual(state(agents: "Use tabs.", claude: "Use tabs.", linked: true), .linked)
        // An import of a file that isn't there: nothing to share.
        XCTAssertEqual(state(claude: "@AGENTS.md"), .none)
        XCTAssertTrue(AgentInstructions.State.split.needsAction)
        XCTAssertFalse(AgentInstructions.State.linked.needsAction)
        XCTAssertFalse(AgentInstructions.State.none.needsAction)
    }

    func testImportsAreOnlyWholeLines() {
        XCTAssertTrue(AgentInstructions.importsAgents("@AGENTS.md"))
        XCTAssertTrue(AgentInstructions.importsAgents("intro\n  @AGENTS.md  \nmore"))
        XCTAssertFalse(AgentInstructions.importsAgents("See @AGENTS.md for more"))
        XCTAssertFalse(AgentInstructions.importsAgents("@AGENTS.md.bak"))
        XCTAssertFalse(AgentInstructions.importsAgents("Use tabs."))
    }

    func testSharingWritesWhatEachCaseNeeds() throws {
        XCTAssertNil(AgentInstructions.plan(for: .init()))
        XCTAssertNil(AgentInstructions.plan(for: .init(agents: "x", claude: "@AGENTS.md")))

        let fromAgents = try XCTUnwrap(AgentInstructions.plan(for: .init(agents: "Use tabs.")))
        XCTAssertNil(fromAgents.agents)
        XCTAssertEqual(fromAgents.claude, "@AGENTS.md\n")
        XCTAssertNil(fromAgents.backupOfClaude)

        // Moving CLAUDE.md's words loses none of them.
        let fromClaude = try XCTUnwrap(AgentInstructions.plan(for: .init(claude: "\nUse tabs.\n@docs/style.md\n")))
        XCTAssertEqual(fromClaude.agents, "Use tabs.\n@docs/style.md\n")
        XCTAssertEqual(fromClaude.claude, "@AGENTS.md\n")
        XCTAssertNil(fromClaude.backupOfClaude)

        let same = try XCTUnwrap(AgentInstructions.plan(for: .init(agents: "Use tabs.\n", claude: "Use tabs.")))
        XCTAssertNil(same.agents)
        XCTAssertNil(same.backupOfClaude)

        let split = try XCTUnwrap(AgentInstructions.plan(for: .init(agents: "Use tabs.", claude: "Use spaces.\n")))
        XCTAssertEqual(split.agents, "Use tabs.\n\n## Also from CLAUDE.md\n\nUse spaces.\n")
        XCTAssertEqual(split.claude, "@AGENTS.md\n")
        XCTAssertEqual(split.backupOfClaude, "Use spaces.\n")
        XCTAssertTrue(split.summary.contains("CLAUDE.md.octet-backup"))
    }

    func testAPlanLeavesTheProjectShared() throws {
        for files in [AgentInstructions.Files(agents: "a"), .init(claude: "c"), .init(agents: "a", claude: "c")] {
            let plan = try XCTUnwrap(AgentInstructions.plan(for: files))
            let after = AgentInstructions.Files(agents: plan.agents ?? files.agents, claude: plan.claude)
            XCTAssertEqual(AgentInstructions.state(of: after), .linked)
            // Doing it again has nothing to do.
            XCTAssertNil(AgentInstructions.plan(for: after))
        }
    }
}
