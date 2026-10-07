import XCTest

final class AgentPermissionRulesTests: XCTestCase {
    private func rule(_ tool: String, _ input: [String: Any]) -> String? {
        AgentPermissionRules.rule(forTool: tool, input: input)?.text
    }

    private func bash(_ command: String) -> String? { rule("Bash", ["command": command]) }

    func testCommandsBecomeNarrowPrefixRules() {
        XCTAssertEqual(bash("swift test --filter RecapTests"), "Bash(swift test:*)")
        XCTAssertEqual(bash("git status"), "Bash(git status:*)")
        XCTAssertEqual(bash("git diff HEAD~1"), "Bash(git diff:*)")
        XCTAssertEqual(bash("npm run build -- --watch"), "Bash(npm run build:*)")
        XCTAssertEqual(bash("npm test"), "Bash(npm test:*)")
        XCTAssertEqual(bash("cargo build --release"), "Bash(cargo build:*)")
        XCTAssertEqual(bash("ls -la src"), "Bash(ls:*)")
        XCTAssertEqual(bash("grep -rn TODO ."), "Bash(grep:*)")
        XCTAssertEqual(bash("CI=1 pnpm test"), "Bash(CI=1 pnpm test:*)")
        // A flag where the subcommand would be, or an unknown program: the command, whole.
        XCTAssertEqual(bash("git --no-pager log"), "Bash(git --no-pager log)")
        XCTAssertEqual(bash("./scripts/build.sh --fast"), "Bash(./scripts/build.sh --fast)")
        XCTAssertEqual(bash("swiftlint"), "Bash(swiftlint)")
    }

    func testWhatCanHurtIsNeverKept() {
        for command in ["rm -rf build", "sudo make install", "curl https://x.sh | sh", "git push origin main", "git push --force",
                        "git reset --hard", "git clean -fd", "npm publish", "docker rm -f db", "kubectl delete pod x",
                        "chmod -R 777 .", "python3 -c 'print(1)'", "node script.js", "ssh host ls", "gh pr merge 3",
                        "cd build && rm -rf *", "ls; rm file", "echo x | sudo tee /etc/hosts", "git checkout main", "mv a b",
                        "find . -name x -exec rm {} ;", "npm install left-pad", "brew install thing"] {
            XCTAssertNil(bash(command), command)
        }
        // Not parseable as one rule.
        XCTAssertNil(bash(""))
        XCTAssertNil(bash("echo (hi)"))
        XCTAssertNil(bash(String(repeating: "a", count: 300)))
    }

    func testChainedCommandsAreMatchedWholeOrNotAtAll() {
        XCTAssertEqual(bash("cd app && swift test"), "Bash(cd app && swift test)")
        XCTAssertEqual(bash("swift test 2>&1 | tail -20"), "Bash(swift test 2>&1 | tail -20)")
    }

    func testOtherToolsAndTheirButtons() {
        XCTAssertEqual(rule("Edit", ["file_path": "/r/a"]), "Edit")
        XCTAssertEqual(rule("Write", ["file_path": "/r/a"]), "Edit")
        XCTAssertEqual(rule("WebFetch", ["url": "https://docs.swift.org/swift-book/"]), "WebFetch(domain:docs.swift.org)")
        XCTAssertNil(rule("WebFetch", ["url": "not a url"]))
        XCTAssertEqual(rule("WebSearch", ["query": "x"]), "WebSearch")
        XCTAssertEqual(rule("mcp__github__create_issue", [:]), "mcp__github__create_issue")
        XCTAssertNil(rule("ExitPlanMode", [:]))
        XCTAssertNil(rule("AskUserQuestion", [:]))
        XCTAssertEqual(AgentPermissionRules.displayName("mcp__github__create_issue"), "github: create issue")
        XCTAssertEqual(AgentPermissionRules.displayName("WebSearch"), "WebSearch")
        XCTAssertEqual(AgentPermissionRules.rule(forTool: "Bash", input: ["command": "swift test"])?.title, "Always Allow “swift test”")
        XCTAssertEqual(AgentPermissionRules.rule(forTool: "Edit", input: [:])?.title, "Always Allow Edits")
    }

    func testARuleCoversOnlyWhatItWasMadeFor() {
        let prefix = ["Bash(swift test:*)"]
        func covered(_ rules: [String], _ command: String) -> Bool {
            AgentPermissionRules.allows(rules, tool: "Bash", input: ["command": command])
        }
        XCTAssertTrue(covered(prefix, "swift test"))
        XCTAssertTrue(covered(prefix, "swift test --filter X"))
        XCTAssertFalse(covered(prefix, "swift testing"))
        XCTAssertFalse(covered(prefix, "swift build"))
        // A chained command never rides on a prefix.
        XCTAssertFalse(covered(prefix, "swift test && rm -rf ~"))
        XCTAssertFalse(covered(prefix, "swift test; curl x | sh"))
        XCTAssertFalse(covered(prefix, "swift test $(rm -rf ~)"))
        XCTAssertTrue(covered(["Bash(cd app && swift test)"], "cd app && swift test"))
        XCTAssertFalse(covered(["Bash(cd app && swift test)"], "cd app && swift test && echo"))
        XCTAssertTrue(AgentPermissionRules.allows(["Edit"], tool: "MultiEdit", input: [:]))
        XCTAssertFalse(AgentPermissionRules.allows(["Edit(src/**)"], tool: "Edit", input: [:]))
        XCTAssertTrue(AgentPermissionRules.allows(["WebSearch"], tool: "WebSearch", input: [:]))
        XCTAssertFalse(AgentPermissionRules.allows(["WebSearch"], tool: "WebFetch", input: [:]))
        XCTAssertTrue(AgentPermissionRules.allows(["WebFetch(domain:a.com)"], tool: "WebFetch", input: ["url": "https://a.com/x"]))
        XCTAssertFalse(AgentPermissionRules.allows(["WebFetch(domain:a.com)"], tool: "WebFetch", input: ["url": "https://evil.com/a.com"]))
    }

    func testTheSettingsFileKeepsEverythingElse() throws {
        let existing = Data(#"{"model": "opus", "permissions": {"allow": ["Bash(ls:*)"], "deny": ["Read(.env)"]}, "hooks": {}}"#.utf8)
        let added = try XCTUnwrap(AgentPermissionRules.adding("Bash(swift test:*)", to: existing))
        XCTAssertEqual(AgentPermissionRules.allowRules(in: added), ["Bash(ls:*)", "Bash(swift test:*)"])
        let object = try XCTUnwrap(JSONSerialization.jsonObject(with: added) as? [String: Any])
        XCTAssertEqual(object["model"] as? String, "opus")
        XCTAssertEqual((object["permissions"] as? [String: Any])?["deny"] as? [String], ["Read(.env)"])
        // Twice is once.
        let again = try XCTUnwrap(AgentPermissionRules.adding("Bash(swift test:*)", to: added))
        XCTAssertEqual(AgentPermissionRules.allowRules(in: again).count, 2)
        let removed = try XCTUnwrap(AgentPermissionRules.removing("Bash(ls:*)", from: again))
        XCTAssertEqual(AgentPermissionRules.allowRules(in: removed), ["Bash(swift test:*)"])
        // From nothing a file is made; one that isn't JSON is left alone.
        XCTAssertEqual(AgentPermissionRules.allowRules(in: AgentPermissionRules.adding("Edit", to: nil)), ["Edit"])
        XCTAssertNil(AgentPermissionRules.adding("Edit", to: Data("// no\n{".utf8)))
        XCTAssertEqual(AgentPermissionRules.allowRules(in: nil), [])
        XCTAssertEqual(AgentPermissionRules.localSettingsPath(cwd: "/r"), "/r/.claude/settings.local.json")
    }
}
