import XCTest

final class DiffPresentationTests: XCTestCase {
    // MARK: - Intraline

    private func marked(_ text: String, _ ranges: [Range<Int>]) -> [String] {
        let characters = Array(text)
        return ranges.map { String(characters[$0]) }
    }

    func testAOneWordEditMarksJustThatWord() throws {
        let old = "    let total = price * count", new = "    let total = price * quantity"
        let found = try XCTUnwrap(IntralineDiff.ranges(old: old, new: new))
        XCTAssertEqual(marked(old, found.old), ["count"])
        XCTAssertEqual(marked(new, found.new), ["quantity"])
    }

    func testAnInsertionMarksOnlyTheNewSide() throws {
        let old = "call(a, b)", new = "call(a, extra, b)"
        let found = try XCTUnwrap(IntralineDiff.ranges(old: old, new: new))
        XCTAssertEqual(found.old, [])
        XCTAssertEqual(marked(new, found.new), ["extra,"])
    }

    func testNeighbouringChangesJoinAcrossASpace() throws {
        let old = "return red green", new = "return blue yellow"
        let found = try XCTUnwrap(IntralineDiff.ranges(old: old, new: new))
        XCTAssertEqual(marked(new, found.new), ["blue yellow"])
    }

    func testARewrittenLineMarksNothing() {
        XCTAssertNil(IntralineDiff.ranges(old: "import Foundation", new: "let x = compute(y)"))
        XCTAssertNil(IntralineDiff.ranges(old: "a b c d e f", new: "a z y x w v"), "one word in six isn't an edit")
    }

    func testOffsetsCountCharactersNotUTF16() throws {
        let old = "let 🙂 = \"héllo\"", new = "let 🙂 = \"hello\""
        let found = try XCTUnwrap(IntralineDiff.ranges(old: old, new: new))
        XCTAssertEqual(marked(old, found.old), ["héllo"])
        XCTAssertEqual(marked(new, found.new), ["hello"])
    }

    func testAHunkPairsRemovedLinesWithTheAddedLinesAfterThem() throws {
        let diff = """
        diff --git a/a.swift b/a.swift
        --- a/a.swift
        +++ b/a.swift
        @@ -1,3 +1,3 @@
         keep
        -let a = 1
        -let b = 2
        +let a = 10
        +let b = 2 // two
        """
        let hunk = try XCTUnwrap(ReviewDiff.parse(diff).first?.hunks.first)
        let ranges = IntralineDiff.ranges(in: hunk)
        let lines = hunk.lines
        XCTAssertEqual(marked(lines[1].text, ranges[lines[1].index] ?? []), ["1"])
        XCTAssertEqual(marked(lines[3].text, ranges[lines[3].index] ?? []), ["10"])
        XCTAssertNil(ranges[lines[2].index], "only words were added to b's line")
        XCTAssertEqual(marked(lines[4].text, ranges[lines[4].index] ?? []), ["// two"])
        XCTAssertNil(ranges[lines[0].index])
    }

    // MARK: - Syntax across hunks

    func testABlockCommentCarriesIntoTheNextHunk() throws {
        let diff = """
        diff --git a/a.c b/a.c
        --- a/a.c
        +++ b/a.c
        @@ -1,1 +1,2 @@
         int x;
        +/* opened here
        @@ -20,1 +21,1 @@
        -int y;
        +still inside */ int y;
        """
        let file = try XCTUnwrap(ReviewDiff.parse(diff).first)
        let spans = file.syntaxSpans()
        let second = file.hunks[1].lines
        // The new side opened a comment; the old side never did.
        XCTAssertEqual(spans[second[1].index]?.first?.kind, .comment)
        XCTAssertNotEqual(spans[second[0].index]?.first?.kind, .comment)
    }

    // MARK: - Folding

    func testLockfilesGeneratedAndLargeFilesFold() {
        XCTAssertEqual(DiffCollapse.reason(path: "web/package-lock.json", changedLines: 3), .lockfile)
        XCTAssertEqual(DiffCollapse.reason(path: "Cargo.lock", changedLines: 3), .lockfile)
        XCTAssertEqual(DiffCollapse.reason(path: "deps/custom.lock", changedLines: 3), .lockfile)
        XCTAssertEqual(DiffCollapse.reason(path: "dist/app.min.js", changedLines: 3), .generated)
        XCTAssertEqual(DiffCollapse.reason(path: "Octet.xcodeproj/project.pbxproj", changedLines: 3), .generated)
        XCTAssertEqual(DiffCollapse.reason(path: "src/__generated__/schema.ts", changedLines: 3), .generated)
        XCTAssertEqual(DiffCollapse.reason(path: "tests/__snapshots__/a.test.ts.snap", changedLines: 3), .generated)
        XCTAssertEqual(DiffCollapse.reason(path: "src/big.swift", changedLines: 4_312), .large(lines: 4_312))
        XCTAssertNil(DiffCollapse.reason(path: "src/generated.swift", changedLines: 10), "a file named so isn't in a generated folder")
        XCTAssertNil(DiffCollapse.reason(path: "src/app.swift", changedLines: 1_000))
    }

    func testFoldReasonsReadPlainly() {
        let english = Locale(identifier: "en_US")
        XCTAssertEqual(DiffCollapse.lockfile.title(locale: english), "Lockfile")
        XCTAssertEqual(DiffCollapse.generated.title(locale: english), "Generated")
        XCTAssertEqual(DiffCollapse.large(lines: 4_312).title(locale: english), "Large: 4,312 lines")
    }

    // MARK: - Marks

    func testEveryListUsesTheSameMarks() {
        XCTAssertEqual(ChangeMark(AgentGit.FileChange.Kind.modified).letter, ChangeMark(ReviewDiff.File.Status.modified).letter)
        XCTAssertEqual(ChangeMark(.untracked).tone, .success)
        XCTAssertEqual(ChangeMark(.renamed).tone, .warning)
        XCTAssertEqual(ChangeMark(.conflicted).letter, "!")
        XCTAssertEqual(ChangeMark(ReviewDiff.File.Status.deleted).tone, .danger)
    }

    // MARK: - Notes

    private let noteDiff = """
    diff --git a/src/app.swift b/src/app.swift
    --- a/src/app.swift
    +++ b/src/app.swift
    @@ -10,3 +10,4 @@
     let a = 1
    -let b = 2
    +let b = 3
    +let c = 4
    """

    func testANoteOnSeveralLinesSaysTheRange() throws {
        let lines = try XCTUnwrap(ReviewDiff.parse(noteDiff).first?.hunks.first?.lines)
        let note = ReviewComment(path: "src/app.swift", line: lines[2], through: lines[3], text: "merge these")
        XCTAssertEqual(note.location, "11-12")
        XCTAssertTrue(ReviewComment.prompt([note]).contains("- src/app.swift:11-12 `let b = 3`"))
        XCTAssertNil(ReviewComment(path: "x", line: lines[0], through: lines[0], text: "t").through)
    }

    func testANoteGoesOutdatedWhenItsLineLeaves() throws {
        let files = ReviewDiff.parse(noteDiff)
        let lines = try XCTUnwrap(files.first?.hunks.first?.lines)
        let note = ReviewComment(path: "src/app.swift", line: lines[3], text: "rename c")
        XCTAssertFalse(note.isOutdated(in: files))
        let rewritten = ReviewDiff.parse(noteDiff.replacingOccurrences(of: "+let c = 4", with: "+let count = 4"))
        XCTAssertTrue(note.isOutdated(in: rewritten))
        XCTAssertTrue(note.isOutdated(in: []), "the file has no changes left")
    }

    func testNotesRideAlongAfterTheMessage() throws {
        let lines = try XCTUnwrap(ReviewDiff.parse(noteDiff).first?.hunks.first?.lines)
        let note = ReviewComment(path: "src/app.swift", line: lines[3], text: "rename c")
        let combined = ReviewComment.attaching([note], to: "  Also run the tests.  ")
        XCTAssertTrue(combined.hasPrefix("Also run the tests.\n\nI reviewed your changes."))
        XCTAssertEqual(ReviewComment.attaching([], to: "hi"), "hi")
    }

    // MARK: - Discard undo

    func testUndoingADiscardPutsTheContentsBackUnlessTheFileMovedOn() throws {
        let top = FileManager.default.temporaryDirectory.appendingPathComponent("octet-discard-\(UUID().uuidString)").path
        try FileManager.default.createDirectory(atPath: top, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(atPath: top) }
        let file = top + "/a.txt"
        try "edited".write(toFile: file, atomically: true, encoding: .utf8)

        var kept = DiscardedFile.capture("a.txt", in: top)
        try "original".write(toFile: file, atomically: true, encoding: .utf8)
        kept.discarded(in: top)
        XCTAssertTrue(kept.canUndo(in: top))
        try kept.undo(in: top)
        XCTAssertEqual(try String(contentsOfFile: file, encoding: .utf8), "edited")

        // Discarded again, then changed: undo would lose the change.
        kept = DiscardedFile.capture("a.txt", in: top)
        try "original".write(toFile: file, atomically: true, encoding: .utf8)
        kept.discarded(in: top)
        try "typed since".write(toFile: file, atomically: true, encoding: .utf8)
        XCTAssertFalse(kept.canUndo(in: top))
        XCTAssertThrowsError(try kept.undo(in: top))
        XCTAssertEqual(try String(contentsOfFile: file, encoding: .utf8), "typed since")
    }

    func testUndoingADeletedUntrackedFileWritesItAgain() throws {
        let top = FileManager.default.temporaryDirectory.appendingPathComponent("octet-discard-\(UUID().uuidString)").path
        try FileManager.default.createDirectory(atPath: top + "/new", withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(atPath: top) }
        try "fresh".write(toFile: top + "/new/b.txt", atomically: true, encoding: .utf8)
        var kept = DiscardedFile.capture("new/b.txt", in: top)
        try FileManager.default.removeItem(atPath: top + "/new")
        kept.discarded(in: top)
        XCTAssertNil(kept.after)
        try kept.undo(in: top)
        XCTAssertEqual(try String(contentsOfFile: top + "/new/b.txt", encoding: .utf8), "fresh")
    }

    // MARK: - Primary git action

    private func action(_ branch: AgentGit.Branch, changes: Int = 0, block: GitCommitBlock? = nil,
                        remote: Bool = true, onBase: Bool = false, aheadOfBase: Int = 0) -> GitPrimaryAction {
        GitPrimaryAction.resolve(branch: branch, changes: changes, commitBlock: block,
                                 hasRemote: remote, onBase: onBase, aheadOfBase: aheadOfBase)
    }

    func testThePrimaryButtonFollowsTheCheckout() {
        let tracked = AgentGit.Branch(name: "feat", upstream: "origin/feat")
        XCTAssertEqual(action(tracked, changes: 2).title, "Commit & Push")
        XCTAssertEqual(action(AgentGit.Branch(name: "feat"), changes: 2).title, "Commit")
        XCTAssertEqual(action(AgentGit.Branch(name: "feat", upstream: "o/f", behind: 1), changes: 2).title, "Commit")
        XCTAssertEqual(action(tracked, changes: 2, block: .emptyMessage).blocked, GitCommitBlock.emptyMessage.reason)

        XCTAssertEqual(action(AgentGit.Branch(name: "feat", upstream: "o/f", behind: 3)).title, "Pull")
        XCTAssertEqual(action(AgentGit.Branch(name: "feat", upstream: "o/f", ahead: 2)).title, "Push")
        XCTAssertEqual(action(AgentGit.Branch(name: "feat"), aheadOfBase: 4).title, "Push & Create PR")
        XCTAssertEqual(action(AgentGit.Branch(name: "main"), onBase: true).title, "Publish Branch")
        XCTAssertNotNil(action(AgentGit.Branch(name: "feat"), remote: false).blocked)

        let diverged = action(AgentGit.Branch(name: "feat", upstream: "origin/feat", ahead: 1, behind: 2))
        XCTAssertEqual(diverged.title, "Sync")
        XCTAssertFalse(diverged.enabled)
        XCTAssertTrue(diverged.blocked?.contains("1 ahead, 2 behind") == true)

        XCTAssertFalse(action(tracked).enabled, "in sync, nothing to do")
        XCTAssertFalse(action(AgentGit.Branch(name: nil)).enabled)
    }
}
