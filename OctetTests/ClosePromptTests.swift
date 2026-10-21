import XCTest

final class ClosePromptTests: XCTestCase {
    func testIdleShellsCloseWithoutAsking() {
        XCTAssertNil(ClosePrompt.question(for: [], place: "tab"))
    }

    func testOneAgentNamesItAndSaysWhatStops() {
        let working = ClosePrompt.question(for: [ClosingWork(agent: "Claude", agentWorking: true)], place: "pane")
        XCTAssertEqual(working?.title, "Stop this agent?")
        XCTAssertEqual(working?.message, "Claude is running in this pane. Closing will stop its current work.")
        XCTAssertEqual(working?.confirmTitle, "Stop Agent")
        XCTAssertEqual(working?.items, [])

        let waiting = ClosePrompt.question(for: [ClosingWork(agent: "Codex")], place: "tab")
        XCTAssertEqual(waiting?.message, "Codex is running in this tab. Closing will end its session.")
    }

    func testOneCommandShowsItShortened() {
        let prompt = ClosePrompt.question(for: [ClosingWork(command: "/usr/local/bin/npm run dev")], place: "tab")
        XCTAssertEqual(prompt?.title, "Stop running command?")
        XCTAssertEqual(prompt?.message, "npm run dev is still running in this tab. Closing will stop it.")
        XCTAssertEqual(prompt?.confirmTitle, "Stop and Close")
    }

    func testSeveralListEachOne() {
        let commands = ClosePrompt.question(for: [ClosingWork(command: "make"), ClosingWork(command: "top")], place: "tab")
        XCTAssertEqual(commands?.title, "Stop 2 running commands?")
        XCTAssertEqual(commands?.items, ["make", "top"])

        let mixed = ClosePrompt.question(for: [ClosingWork(agent: "Claude", agentWorking: true), ClosingWork(command: "make")],
                                         place: "tab")
        XCTAssertEqual(mixed?.title, "Stop the agents and commands?")
        XCTAssertEqual(mixed?.items, ["Claude", "make"])

        let agents = ClosePrompt.question(for: [ClosingWork(agent: "Claude"), ClosingWork(agent: "Codex")], place: "tab")
        XCTAssertEqual(agents?.title, "Stop 2 agents?")
    }

    func testSubagentViewersStopNothing() {
        let pane = EnginePane(paneId: "p1", tabId: "t1", workspaceId: "w1", focused: true, cwd: nil, foregroundCwd: nil,
                              agentStatus: .working, terminalTitle: nil)
        let agent = EngineAgent(paneId: "p1", tabId: "t1", workspaceId: "w1", agent: "claude", name: nil, displayAgent: nil,
                                agentStatus: .working)
        XCTAssertEqual(ClosingWork.agent(in: pane, agents: [agent])?.agentWorking, true)
        XCTAssertNotNil(ClosingWork.agent(in: pane, agents: [agent])?.agent)
        var viewer = agent
        viewer.tokens = [PaneAgentReporter.roleToken: PaneAgentReporter.subagentRole]
        XCTAssertNil(ClosingWork.agent(in: pane, agents: [viewer]))
    }
}
