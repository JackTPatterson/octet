import XCTest

final class BestOfNTests: XCTestCase {
    private let claude = BestOfN.Runner(id: "claude", name: "Claude Code", executable: "/bin/claude")
    private let codex = BestOfN.Runner(id: "codex", name: "Codex", executable: "/bin/codex")
    private let pi = BestOfN.Runner(id: "pi", name: "Pi", executable: "/bin/pi")

    func testEachAgentTriesOnceOrOneTriesTwice() {
        XCTAssertEqual(BestOfN.plan([pi, codex, claude]).map(\.id), ["claude", "codex"])
        XCTAssertEqual(BestOfN.plan([codex, pi]).map(\.id), ["codex", "codex"])
        XCTAssertEqual(BestOfN.plan([pi]), [])
    }

    func testBranchesAreNamedAfterTheTaskAndNeverCollide() {
        let names = BestOfN.branches(task: "Fix the login bug, please!", runners: [claude, claude, codex],
                                     existing: ["try/fix-the-login-bug-codex"])
        XCTAssertEqual(names, ["try/fix-the-login-bug-claude", "try/fix-the-login-bug-claude-2", "try/fix-the-login-bug-codex-2"])
        XCTAssertEqual(BestOfN.branches(task: "!!!", runners: [codex], existing: []), ["try/task-codex"])
    }

    func testTheCommandQuotesTheTask() {
        XCTAssertEqual(BestOfN.command(for: codex, task: "it's done", quote: { "'" + $0.replacingOccurrences(of: "'", with: "'\\''") + "'" }),
                       "'/bin/codex' 'it'\\''s done'")
    }
}
