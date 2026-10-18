import XCTest

final class TranscriptFeaturesTests: XCTestCase {
    // MARK: - Changed files per turn

    private func tool(_ id: String, _ name: String, _ input: [String: Any], error: Bool = false) -> AgentItem {
        var call = AgentToolCall(name: name, summary: "", input: "", inputData: try? JSONSerialization.data(withJSONObject: input))
        call.result = "ok"
        call.isError = error
        return AgentItem(id: id, kind: .tool(call))
    }

    private func user(_ id: String, at seconds: TimeInterval) -> AgentItem {
        AgentItem(id: id, kind: .user("go"), createdAt: Date(timeIntervalSince1970: seconds))
    }

    func testEachTurnCollectsTheFilesItsEditToolsChangedWithCounts() {
        let items = [
            user("u1", at: 100),
            tool("e1", "Edit", ["file_path": "/p/Sources/A.swift", "old_string": "a\nb", "new_string": "a\nc\nd"]),
            tool("w1", "Write", ["file_path": "/p/Tests/ATests.swift", "content": "one\ntwo\nthree"]),
            tool("e2", "Edit", ["file_path": "/p/Sources/A.swift", "old_string": "x", "new_string": "y"]),
            tool("r1", "Read", ["file_path": "/p/README.md"]),
            AgentItem(id: "t1", kind: .text("done")),
            user("u2", at: 200),
            AgentItem(id: "t2", kind: .text("nothing to change")),
        ]
        let turns = TurnChanges.derive(items, cwd: "/p")
        XCTAssertEqual(turns.count, 1, "A turn that edited nothing has no card")
        let turn = turns[0]
        XCTAssertEqual(turn.promptId, "u1")
        XCTAssertEqual(turn.number, 1)
        XCTAssertEqual(turn.lastItemId, "t1")
        XCTAssertEqual(turn.promptAt, Date(timeIntervalSince1970: 100))
        XCTAssertEqual(turn.nextPromptAt, Date(timeIntervalSince1970: 200))
        XCTAssertEqual(turn.files.map(\.path), ["/p/Sources/A.swift", "/p/Tests/ATests.swift"])
        let a = turn.files[0]
        XCTAssertEqual(a.added, 3, "Both edits to a file add up")
        XCTAssertEqual(a.removed, 2)
        XCTAssertFalse(a.created)
        XCTAssertEqual(turn.files[1].added, 3)
        XCTAssertTrue(turn.files[1].created)
        XCTAssertEqual(turn.added, 6)
        XCTAssertEqual(turn.removed, 2)
    }

    func testFailedEditsAndTheRunningTurnAreLeftOut() {
        let items = [
            user("u1", at: 0),
            tool("e1", "Edit", ["file_path": "/p/A.swift", "old_string": "a", "new_string": "b"], error: true),
            user("u2", at: 10),
            tool("e2", "Edit", ["file_path": "/p/B.swift", "old_string": "a", "new_string": "b"]),
        ]
        XCTAssertTrue(TurnChanges.derive(items, cwd: "/p", running: true).isEmpty)
        let finished = TurnChanges.derive(items, cwd: "/p", running: false)
        XCTAssertEqual(finished.map(\.number), [2])
        XCTAssertNil(finished[0].nextPromptAt)
    }

    func testCodexFileChangesCountTheirUnifiedDiffAndResolveAgainstTheFolder() {
        let diff = "--- a/src/main.rs\n+++ b/src/main.rs\n@@ -1,3 +1,3 @@\n fn main() {\n-    old();\n+    new();\n+    more();\n }"
        let items = [
            user("u1", at: 0),
            tool("c1", "Edit", ["type": "fileChange", "changes": [
                ["path": "src/main.rs", "kind": ["type": "update"], "diff": diff],
                ["path": "src/new.rs", "kind": "add", "diff": "+fn x() {}"],
            ]]),
        ]
        let files = TurnChanges.derive(items, cwd: "/repo")[0].files
        XCTAssertEqual(files.map(\.path), ["/repo/src/main.rs", "/repo/src/new.rs"])
        XCTAssertEqual(files[0].added, 2)
        XCTAssertEqual(files[0].removed, 1)
        XCTAssertEqual(files[0].lines.first?.kind, .context)
        XCTAssertEqual(files[0].lines.first(where: { $0.kind == .added })?.newNumber, 2)
        XCTAssertTrue(files[1].created)
    }

    func testTheTreeJoinsSingleFolderChainsAndPutsFoldersFirst() {
        func file(_ path: String) -> TurnChanges.File {
            TurnChanges.File(path: path, added: 1, removed: 0, lines: [], created: false)
        }
        let tree = ChangedFileNode.tree([file("/p/Sources/App/Retry/Backoff.swift"),
                                         file("/p/Sources/App/Uploader.swift"),
                                         file("/p/README.md")], root: "/p")
        XCTAssertEqual(tree.map(\.name), ["Sources/App", "README.md"])
        guard case .folder(_, let path, let children) = tree[0] else { return XCTFail("Expected a folder") }
        XCTAssertEqual(path, "Sources/App")
        XCTAssertEqual(children.map(\.name), ["Retry", "Uploader.swift"])
        XCTAssertEqual(tree[0].added, 2)
    }

    // MARK: - Media links

    func testMediaIsFoundInMarkdownBareAddressesAndPaths() {
        let text = """
        Here's the shot: ![after](./shots/after.png) and the old one at /tmp/before.JPG.
        Video: https://example.com/demo.mp4?x=1, and [a link](https://example.com/page) that isn't media.
        Also `out/clip.mov` and ~/Desktop/screen.gif
        """
        let links = TranscriptMediaLink.links(in: text, cwd: "/repo")
        XCTAssertEqual(links.map(\.source), ["./shots/after.png", "/tmp/before.JPG", "https://example.com/demo.mp4?x=1",
                                             "out/clip.mov", "~/Desktop/screen.gif"])
        XCTAssertEqual(links.map(\.kind), [.image, .image, .video, .video, .image])
        XCTAssertEqual(links[0].url.path, "/repo/shots/after.png")
        XCTAssertTrue(links[0].isFile)
        XCTAssertFalse(links[2].isFile)
        XCTAssertEqual(links[4].url.path, NSHomeDirectory() + "/Desktop/screen.gif")
    }

    func testCodeFencesUnknownExtensionsAndRepeatsAreIgnored() {
        let text = """
        See /tmp/a.png and again /tmp/a.png.
        ```
        cp /tmp/inside-fence.png /tmp/b.png
        ```
        The log is at /tmp/run.log and the page at https://example.com/a.html
        """
        XCTAssertEqual(TranscriptMediaLink.links(in: text).map(\.source), ["/tmp/a.png"])
    }

    func testARelativePathOutsideCodeNeedsAFolderToResolve() {
        XCTAssertTrue(TranscriptMediaLink.links(in: "`shot.png`").isEmpty)
        XCTAssertEqual(TranscriptMediaLink.links(in: "`shot.png`", cwd: "/r").first?.url.path, "/r/shot.png")
    }

    // MARK: - Quoting

    func testQuotingAppendsABlockquoteToTheDraft() {
        XCTAssertEqual(TranscriptQuote.blockquote("  first line\n\nsecond  "), "> first line\n>\n> second")
        XCTAssertEqual(TranscriptQuote.inserting("the passage", into: ""), "> the passage\n\n")
        XCTAssertEqual(TranscriptQuote.inserting("the passage", into: "Earlier draft  \n"),
                       "Earlier draft\n\n> the passage\n\n")
        XCTAssertEqual(TranscriptQuote.inserting("the passage", into: "", action: .ask),
                       "> the passage\n\nCan you explain this part?")
        XCTAssertEqual(TranscriptQuote.inserting("   ", into: "keep"), "keep")
        let long = String(repeating: "a", count: TranscriptQuote.maxLength + 50)
        XCTAssertEqual(TranscriptQuote.blockquote(long).count, TranscriptQuote.maxLength + 3)
    }

    // MARK: - Output search

    func testOutputSearchFindsLinesIgnoringCaseAndColour() {
        let plain = CommandOutputSearch.plain("\u{1B}[31merror\u{1B}[0m: one\nok\nERROR two")
        XCTAssertEqual(plain, "error: one\nok\nERROR two")
        let lines = plain.components(separatedBy: "\n")
        XCTAssertEqual(CommandOutputSearch.matchingLines(lines, query: "error"), [0, 2])
        XCTAssertEqual(CommandOutputSearch.matchingLines(lines, query: "  "), [])
    }
}
