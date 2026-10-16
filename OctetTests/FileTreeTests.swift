import XCTest

final class FileTreeTests: XCTestCase {
    func testFoldersComeFirstAndNest() {
        let tree = FileTreeNode.build(["README.md", "Sources/App/main.swift", "Sources/App/View.swift", "Package.swift", "Sources/Lib.swift"])
        XCTAssertEqual(tree.map(\.name), ["Sources", "Package.swift", "README.md"])
        XCTAssertEqual(tree[0].children.map(\.name), ["App", "Lib.swift"])
        XCTAssertEqual(tree[0].children[0].children.map(\.path), ["Sources/App/main.swift", "Sources/App/View.swift"])
    }

    func testRowsSkipFoldedFolders() {
        let tree = FileTreeNode.build(["a/b.txt", "c.txt"])
        XCTAssertEqual(FileTreeNode.rows(tree, open: []).map(\.node.path), ["a", "c.txt"])
        let open = FileTreeNode.rows(tree, open: ["a"])
        XCTAssertEqual(open.map(\.node.path), ["a", "a/b.txt", "c.txt"])
        XCTAssertEqual(open[1].depth, 1)
    }

    func testDiffArgumentsIgnoreWhitespaceOnlyWhenAsked() {
        XCTAssertFalse(ReviewDiff.diffArguments("a", "b").contains("-w"))
        let args = ReviewDiff.diffArguments("a", "b", ignoreWhitespace: true)
        XCTAssertEqual(Array(args.suffix(3)), ["-w", "a", "b"])
    }

    func testTurnsRunFromEachCheckpointToTheNext() {
        let points = [3, 2, 1].map { Checkpoint(ref: "r\($0)", commit: "c\($0)", date: Date(timeIntervalSince1970: Double($0)), label: "") }
        let turns = ReviewDiff.turns(points)
        XCTAssertEqual(turns.map(\.title), ["Latest Turn", "Turn 2", "Turn 1"])
        XCTAssertEqual(turns[0].base, .turn(from: "c3", to: nil, name: "turn 3"))
        XCTAssertEqual(turns[2].base, .turn(from: "c1", to: "c2", name: "turn 1"))
    }
}
