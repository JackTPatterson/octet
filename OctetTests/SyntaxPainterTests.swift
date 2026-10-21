import AppKit
import XCTest
@testable import Octet

@MainActor
final class SyntaxPainterTests: XCTestCase {
    private let painter = SyntaxPainter(font: .monospacedSystemFont(ofSize: 12, weight: .regular),
                                        palette: ThemePalette(theme: .named("Dark")))

    private func colors(_ storage: NSTextStorage) -> [NSColor?] {
        (0..<storage.length).map { storage.attribute(.foregroundColor, at: $0, effectiveRange: nil) as? NSColor }
    }

    func testCRLFDoesNotShiftColours() {
        let text = "let a = 1\r\nlet b = 2\r\nlet c = 3"
        let storage = NSTextStorage(string: text)
        painter.paintAll(storage)
        let keyword = painter.palette.nsColor(\.syntaxFlag)
        // "let" at the start of each line, CRLF or not.
        for start in [0, 11, 22] {
            XCTAssertEqual(storage.attribute(.foregroundColor, at: start, effectiveRange: nil) as? NSColor, keyword)
            XCTAssertEqual(storage.attribute(.foregroundColor, at: start + 2, effectiveRange: nil) as? NSColor, keyword)
        }
    }

    func testIncrementalPaintMatchesAFullOne() {
        let storage = NSTextStorage(string: "let a = 1\nlet b = \"s\"\n// note\nlet c = 3\n")
        painter.paintAll(storage)
        // Open a block comment on line one: every line after it changes.
        storage.replaceCharacters(in: NSRange(location: 0, length: 0), with: "/* ")
        let painted = painter.paint(storage, edited: NSRange(location: 0, length: 3))
        XCTAssertEqual(painted.location, 0)

        let fresh = NSTextStorage(string: storage.string)
        painter.paintAll(fresh)
        XCTAssertEqual(colors(storage), colors(fresh))
    }

    func testAnEditStopsOnceTheStateSettles() {
        let lines = (0..<200).map { "let value\($0) = \($0)" }.joined(separator: "\n")
        let storage = NSTextStorage(string: lines)
        painter.paintAll(storage)
        let line = (storage.string as NSString).lineRange(for: NSRange(location: 50, length: 0))
        storage.replaceCharacters(in: NSRange(location: line.location, length: 0), with: "x")
        let painted = painter.paint(storage, edited: NSRange(location: line.location, length: 1))
        // The edited line and, at most, the one after it.
        XCTAssertLessThan(painted.length, line.length * 3)
    }
}
