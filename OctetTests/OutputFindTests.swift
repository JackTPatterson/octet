import XCTest

final class OutputFindTests: XCTestCase {
    func testTheServerSearchesUnlessItCantMatchAsAsked() {
        XCTAssertFalse(OutputFind.searchesLocally(query: "error", caseSensitive: false, regex: false, serverHasOptions: false))
        // A stock server matches case once there's a capital.
        XCTAssertFalse(OutputFind.searchesLocally(query: "Error", caseSensitive: true, regex: false, serverHasOptions: false))
        XCTAssertTrue(OutputFind.searchesLocally(query: "error", caseSensitive: true, regex: false, serverHasOptions: false))
        XCTAssertTrue(OutputFind.searchesLocally(query: "err.r", caseSensitive: false, regex: true, serverHasOptions: false))
        // Octet's own takes both options, over the whole buffer.
        XCTAssertFalse(OutputFind.searchesLocally(query: "err.r", caseSensitive: true, regex: true, serverHasOptions: true))
        let plain = OutputFind.serverParameters(query: "Error", caseSensitive: false, regex: false)
        XCTAssertEqual(plain["query"] as? String, "error")
        XCTAssertEqual(plain["case_sensitive"] as? Bool, false)
        let pattern = OutputFind.serverParameters(query: #"E\d+"#, caseSensitive: false, regex: true)
        XCTAssertEqual(pattern["query"] as? String, #"E\d+"#)
        XCTAssertEqual(pattern["regex"] as? Bool, true)
    }

    func testMatchesAreInBufferRowsAndCells() throws {
        let lines = ["build ok", "日本 Error here", "error again error"]
        let found = try OutputFind.matches(in: lines, firstRow: 100, query: "error", caseSensitive: false, regex: false)
        XCTAssertEqual(found.map(\.start.row), [101, 102, 102])
        // Two wide characters and a space put it at cell 5.
        XCTAssertEqual(found[0].start.col, 5)
        XCTAssertEqual(found[0].end.col, 9)
        XCTAssertEqual(found[2].start.col, 12)

        let exact = try OutputFind.matches(in: lines, firstRow: 0, query: "error", caseSensitive: true, regex: false)
        XCTAssertEqual(exact.count, 2)
    }

    func testRegularExpressionsAndLiterals() throws {
        let lines = ["a.b axb", "v1.2.3"]
        XCTAssertEqual(try OutputFind.matches(in: lines, firstRow: 0, query: "a.b", caseSensitive: false, regex: false).count, 1)
        XCTAssertEqual(try OutputFind.matches(in: lines, firstRow: 0, query: "a.b", caseSensitive: false, regex: true).count, 2)
        XCTAssertEqual(try OutputFind.matches(in: lines, firstRow: 0, query: #"\d+"#, caseSensitive: false, regex: true).count, 3)
        // An empty match isn't one.
        XCTAssertEqual(try OutputFind.matches(in: lines, firstRow: 0, query: "z*", caseSensitive: false, regex: true).count, 0)
        XCTAssertThrowsError(try OutputFind.matches(in: lines, firstRow: 0, query: "(", caseSensitive: false, regex: true)) {
            XCTAssertEqual(OutputFind.describe($0), "Invalid pattern")
        }
    }

    func testStepsStartAtTheNewestAndWrap() {
        XCTAssertNil(OutputFind.step(from: nil, backward: true, count: 0))
        XCTAssertEqual(OutputFind.step(from: nil, backward: true, count: 3), 2)
        XCTAssertEqual(OutputFind.step(from: 0, backward: true, count: 3), 2)
        XCTAssertEqual(OutputFind.step(from: 2, backward: false, count: 3), 0)
    }

    func testRowsAndScrolling() {
        XCTAssertEqual(OutputFind.rows(of: "a\nb\n"), ["a", "b"])
        let match = TerminalSearchMatch(start: .init(row: 500, col: 0), end: .init(row: 500, col: 3))
        XCTAssertEqual(OutputFind.scrollOffset(for: match, maximum: 960, viewportRows: 40), 480)
        XCTAssertEqual(OutputFind.scrollOffset(for: match, maximum: 100, viewportRows: 40), 0)
    }

    func testErrorsReadAsWords() {
        XCTAssertEqual(OutputFind.describe(EngineSocketError.server(code: "not_found", message: "x")), "This pane has closed")
        XCTAssertEqual(OutputFind.describe(EngineSocketError.closed), "Lost the connection to the terminal")
        XCTAssertEqual(OutputFind.describe(EngineSocketError.server(code: "invalid_regex", message: "unclosed group")),
                       "Invalid pattern")
        XCTAssertEqual(OutputFind.describe(EngineSocketError.malformedResponse("junk")), "Couldn't search this pane")
    }
}
