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
}
