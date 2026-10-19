import XCTest
@testable import Octet

final class FilePreviewModeTests: XCTestCase {
    func testModeByExtension() {
        XCTAssertEqual(FilePreviewMode.mode(forPath: "/a/b.PNG"), .image)
        XCTAssertEqual(FilePreviewMode.mode(forPath: "/a/b.heic"), .image)
        XCTAssertEqual(FilePreviewMode.mode(forPath: "/a/logo.svg"), .svg)
        XCTAssertEqual(FilePreviewMode.mode(forPath: "/a/data.csv"), .table)
        XCTAssertEqual(FilePreviewMode.mode(forPath: "/a/data.TSV"), .table)
        XCTAssertEqual(FilePreviewMode.mode(forPath: "/a/song.mp3"), .audio)
        XCTAssertEqual(FilePreviewMode.mode(forPath: "/a/clip.mov"), .video)
        XCTAssertEqual(FilePreviewMode.mode(forPath: "/a/doc.pdf"), .pdf)
        XCTAssertEqual(FilePreviewMode.mode(forPath: "/a/README.md"), .markdown)
        XCTAssertEqual(FilePreviewMode.mode(forPath: "/a/app.zip"), .binary)
        XCTAssertEqual(FilePreviewMode.mode(forPath: "/a/main.swift"), .text)
        XCTAssertEqual(FilePreviewMode.mode(forPath: "/a/Makefile"), .text)
    }

    func testTextAndToggleKinds() {
        XCTAssertTrue(FilePreviewMode.svg.readsText)
        XCTAssertTrue(FilePreviewMode.table.readsText)
        XCTAssertFalse(FilePreviewMode.image.readsText)
        XCTAssertFalse(FilePreviewMode.binary.readsText)
        XCTAssertTrue(FilePreviewMode.svg.hasSourceToggle)
        XCTAssertTrue(FilePreviewMode.table.hasSourceToggle)
        XCTAssertFalse(FilePreviewMode.markdown.hasSourceToggle)
        XCTAssertFalse(FilePreviewMode.text.hasSourceToggle)
    }

    func testDelimiter() {
        XCTAssertEqual(FilePreviewMode.delimiter(forPath: "x.csv"), ",")
        XCTAssertEqual(FilePreviewMode.delimiter(forPath: "x.tsv"), "\t")
    }

    func testBreadcrumbsInsideAndOutsideProject() {
        let inside = FileBreadcrumbs.segments(file: URL(fileURLWithPath: "/tmp/proj/src/ui/a.png"), root: "/tmp/proj")
        XCTAssertEqual(inside.map(\.name), ["proj", "src", "ui", "a.png"])
        XCTAssertEqual(inside.map(\.folder), [
            URL(fileURLWithPath: "/tmp/proj").resolvingSymlinksInPath().path,
            URL(fileURLWithPath: "/tmp/proj").resolvingSymlinksInPath().path + "/src",
            URL(fileURLWithPath: "/tmp/proj").resolvingSymlinksInPath().path + "/src/ui", nil])
        let outside = FileBreadcrumbs.segments(file: URL(fileURLWithPath: "/etc/hosts"), root: "/tmp/proj")
        XCTAssertEqual(outside.last?.name, "hosts")
        XCTAssertTrue(outside.allSatisfy { $0.folder == nil })
    }
}

final class DelimitedTableTests: XCTestCase {
    func testPlainRows() {
        let parsed = DelimitedTable.parse("a,b,c\n1,2,3\n4,5,6\n")
        XCTAssertEqual(parsed.rows, [["a", "b", "c"], ["1", "2", "3"], ["4", "5", "6"]])
        XCTAssertFalse(parsed.truncated)
    }

    func testQuotedFields() {
        let parsed = DelimitedTable.parse("name,note\n\"Smith, Jo\",\"said \"\"hi\"\"\"\n")
        XCTAssertEqual(parsed.rows[1], ["Smith, Jo", "said \"hi\""])
    }

    func testEmbeddedNewlinesAndCRLF() {
        let parsed = DelimitedTable.parse("a,b\r\n\"line1\nline2\",x\r\ny,z")
        XCTAssertEqual(parsed.rows, [["a", "b"], ["line1\nline2", "x"], ["y", "z"]])
    }

    func testTabSeparated() {
        let parsed = DelimitedTable.parse("a\tb\n1,5\t\"x\ty\"\n", delimiter: "\t")
        XCTAssertEqual(parsed.rows, [["a", "b"], ["1,5", "x\ty"]])
    }

    func testEmptyCellsAndBlankLines() {
        let parsed = DelimitedTable.parse("a,,c\n\n,,\n")
        XCTAssertEqual(parsed.rows, [["a", "", "c"], ["", "", ""]])
    }

    func testRowCap() {
        let text = (0..<10).map { "\($0),x" }.joined(separator: "\n")
        let capped = DelimitedTable.parse(text, maximumRows: 3)
        XCTAssertEqual(capped.rows.count, 4)
        XCTAssertTrue(capped.truncated)
        XCTAssertFalse(DelimitedTable.parse(text, maximumRows: 20).truncated)
    }

    func testSortNumbersByValueAndTextNaturally() {
        let rows = [["10"], ["9"], ["100"]]
        XCTAssertEqual(DelimitedTable.order(rows, column: 0, ascending: true), [1, 0, 2])
        XCTAssertEqual(DelimitedTable.order(rows, column: 0, ascending: false), [2, 0, 1])
        XCTAssertEqual(DelimitedTable.order(rows, column: nil, ascending: true), [0, 1, 2])
        let names = [["b"], ["a"], ["c"]]
        XCTAssertEqual(DelimitedTable.order(names, column: 0, ascending: true), [1, 0, 2])
    }
}
