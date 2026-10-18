import XCTest

final class ProjectSearchTests: XCTestCase {
    // MARK: ripgrep JSON

    func testReadsARipgrepMatch() {
        let line = #"{"type":"match","data":{"path":{"text":"./Shared/IdleShelves.swift"},"lines":{"text":"    func wakeTime(now: Date) -> Date? {\n"},"line_number":32,"absolute_offset":992,"submatches":[{"match":{"text":"wakeTime"},"start":9,"end":17},{"match":{"text":"Date"},"start":23,"end":27}]}}"#
        let match = RipgrepJSON.match(fromLine: line)
        XCTAssertEqual(match, ProjectSearchMatch(path: "Shared/IdleShelves.swift", line: 32,
                                                 text: "    func wakeTime(now: Date) -> Date? {",
                                                 ranges: [9..<17, 23..<27]))
        XCTAssertEqual(match?.fileName, "IdleShelves.swift")
        XCTAssertEqual(match?.directory, "Shared")
    }

    func testIgnoresRipgrepsOtherEvents() {
        XCTAssertNil(RipgrepJSON.match(fromLine: #"{"type":"begin","data":{"path":{"text":"a.swift"}}}"#))
        XCTAssertNil(RipgrepJSON.match(fromLine: #"{"type":"end","data":{"path":{"text":"a.swift"},"binary_offset":null,"stats":{}}}"#))
        XCTAssertNil(RipgrepJSON.match(fromLine: #"{"data":{"elapsed_total":{"secs":0}},"type":"summary"}"#))
        XCTAssertNil(RipgrepJSON.match(fromLine: "not json"))
        // A line that isn't UTF-8 comes as base64 bytes, with nothing to show.
        XCTAssertNil(RipgrepJSON.match(fromLine: #"{"type":"match","data":{"path":{"text":"a.bin"},"lines":{"bytes":"/w=="},"line_number":1,"absolute_offset":0,"submatches":[]}}"#))
    }

    /// ripgrep counts bytes; the ranges come back in UTF-16, which is what
    /// the row and the editor count in.
    func testConvertsByteOffsetsToUTF16() {
        // "é" is 2 bytes and 1 UTF-16 unit; "😀" is 4 bytes and 2 units.
        let line = #"{"type":"match","data":{"path":{"text":"a.txt"},"lines":{"text":"é😀 café hit\r\n"},"line_number":3,"absolute_offset":0,"submatches":[{"match":{"text":"café"},"start":7,"end":12},{"match":{"text":"hit"},"start":13,"end":16}]}}"#
        let match = RipgrepJSON.match(fromLine: line)
        XCTAssertEqual(match?.text, "é😀 café hit")
        XCTAssertEqual(match?.ranges, [4..<8, 9..<12])
        let text = match!.text as NSString
        XCTAssertEqual(text.substring(with: NSRange(location: 4, length: 4)), "café")
        XCTAssertEqual(text.substring(with: NSRange(location: 9, length: 3)), "hit")
    }

    func testDropsSubmatchesOutsideTheLine() {
        let line = #"{"type":"match","data":{"path":{"text":"a"},"lines":{"text":"abc\n"},"line_number":1,"absolute_offset":0,"submatches":[{"match":{"text":"x"},"start":2,"end":99},{"match":{"text":"x"},"start":5,"end":4},{"match":{"text":"b"},"start":1,"end":2}]}}"#
        XCTAssertEqual(RipgrepJSON.match(fromLine: line)?.ranges, [1..<2])
    }

    // MARK: git grep

    func testReadsGitGrepOutput() throws {
        let matcher = try XCTUnwrap(ProjectSearchMatcher(ProjectSearchOptions(query: "snooze")))
        let match = GitGrepOutput.match(fromLine: "Octet/a:b.swift\u{0}12\u{0}  store.Snooze(id, choice) // snooze", matcher: matcher)
        XCTAssertEqual(match?.path, "Octet/a:b.swift")
        XCTAssertEqual(match?.line, 12)
        XCTAssertEqual(match?.ranges, [8..<14, 30..<36])
        XCTAssertNil(GitGrepOutput.match(fromLine: "no separators", matcher: matcher))
        XCTAssertNil(GitGrepOutput.match(fromLine: "a\u{0}x\u{0}text", matcher: matcher))
    }

    // MARK: Matching options

    func testMatcherHonoursCaseWordAndRegex() throws {
        let text = "Snooze snoozed SNOOZE a.b axb"
        XCTAssertEqual(ProjectSearchMatcher(ProjectSearchOptions(query: "snooze"))?.ranges(in: text).count, 3)
        XCTAssertEqual(ProjectSearchMatcher(ProjectSearchOptions(query: "snooze", caseSensitive: true))?.ranges(in: text),
                       [7..<13])
        XCTAssertEqual(ProjectSearchMatcher(ProjectSearchOptions(query: "snooze", wholeWord: true))?.ranges(in: text),
                       [0..<6, 15..<21])
        // Without regex a "." is a dot.
        XCTAssertEqual(ProjectSearchMatcher(ProjectSearchOptions(query: "a.b"))?.ranges(in: text), [22..<25])
        XCTAssertEqual(ProjectSearchMatcher(ProjectSearchOptions(query: "a.b", regex: true))?.ranges(in: text),
                       [22..<25, 26..<29])
        XCTAssertNil(ProjectSearchMatcher(ProjectSearchOptions(query: "(unclosed", regex: true)))
        XCTAssertNotNil(ProjectSearchMatcher(ProjectSearchOptions(query: "(unclosed")))
        XCTAssertNil(ProjectSearchMatcher(ProjectSearchOptions(query: "")))
    }

    func testToolArguments() {
        var options = ProjectSearchOptions(query: "-v", include: "*.swift, !*Tests*")
        XCTAssertEqual(options.globs, ["*.swift", "!*Tests*"])
        let rg = options.ripgrepArguments
        XCTAssertTrue(rg.contains("--fixed-strings"))
        XCTAssertTrue(rg.contains("--ignore-case"))
        // The query is given with --regexp, so one starting "-" isn't a flag.
        XCTAssertEqual(Array(rg.suffix(4)), ["--regexp", "-v", "--", "."])
        XCTAssertEqual(rg.filter { $0 == "--glob" }.count, 3)
        options.regex = true
        options.caseSensitive = true
        options.wholeWord = true
        XCTAssertFalse(options.ripgrepArguments.contains("--fixed-strings"))
        XCTAssertTrue(options.ripgrepArguments.contains("--word-regexp"))
        XCTAssertTrue(options.ripgrepArguments.contains("--case-sensitive"))

        let git = ProjectSearchOptions(query: "x", include: "!*.lock").gitGrepArguments
        XCTAssertEqual(Array(git.suffix(5)), ["-e", "x", "--", ".", ":(exclude)*.lock"])
        XCTAssertTrue(git.contains("-i"))
        XCTAssertTrue(git.contains("-F"))
    }

    // MARK: Highlighting

    func testNormalizesRanges() {
        XCTAssertEqual(ProjectSearchHighlight.normalized([8..<12, 0..<3, 2..<5, 5..<6, 20..<30, 4..<4], length: 25),
                       [0..<6, 8..<12, 20..<25])
        XCTAssertEqual(ProjectSearchHighlight.normalized([30..<40], length: 25), [])
    }

    func testSplitsALineIntoMatchedRuns() {
        let segments = ProjectSearchHighlight.segments("let foo = foo()", ranges: [10..<13, 4..<7])
        XCTAssertEqual(segments, [
            .init(text: "let ", isMatch: false),
            .init(text: "foo", isMatch: true),
            .init(text: " = ", isMatch: false),
            .init(text: "foo", isMatch: true),
            .init(text: "()", isMatch: false),
        ])
        XCTAssertEqual(ProjectSearchHighlight.segments("ab", ranges: [0..<2]), [.init(text: "ab", isMatch: true)])
        XCTAssertEqual(ProjectSearchHighlight.segments("ab", ranges: []), [.init(text: "ab", isMatch: false)])
        // Ranges count UTF-16, so an emoji before the match doesn't shift it.
        XCTAssertEqual(ProjectSearchHighlight.segments("😀ok", ranges: [2..<4]),
                       [.init(text: "😀", isMatch: false), .init(text: "ok", isMatch: true)])
    }

    func testPreviewDropsIndentAndBringsAFarMatchIntoView() {
        let indented = ProjectSearchHighlight.preview("        return x", ranges: [15..<16])
        XCTAssertEqual(indented.text, "return x")
        XCTAssertEqual(indented.ranges, [7..<8])

        let long = String(repeating: "a", count: 100) + "needle" + "b"
        let far = ProjectSearchHighlight.preview(long, ranges: [100..<106], lead: 10)
        XCTAssertTrue(far.text.hasPrefix("…"))
        XCTAssertEqual(far.ranges, [11..<17])
        let shown = far.text as NSString
        XCTAssertEqual(shown.substring(with: NSRange(location: 11, length: 6)), "needle")

        let capped = ProjectSearchHighlight.preview(String(repeating: "x", count: 1000), ranges: [0..<1], maxLength: 50)
        XCTAssertEqual((capped.text as NSString).length, 50)
    }

    func testGroupsByFileKeepingFlatIndices() {
        let a1 = ProjectSearchMatch(path: "a", line: 1, text: "", ranges: [])
        let b1 = ProjectSearchMatch(path: "b", line: 4, text: "", ranges: [])
        let a2 = ProjectSearchMatch(path: "a", line: 9, text: "", ranges: [])
        let groups = ProjectSearchGroups.group([a1, b1, a2])
        XCTAssertEqual(groups.map(\.path), ["a", "b"])
        XCTAssertEqual(groups[0].matches.map(\.index), [0, 2])
        XCTAssertEqual(groups[1].matches.map(\.index), [1])
    }

    // MARK: The scan's file filter

    func testScanAppliesIncludeAndExcludeGlobs() {
        XCTAssertTrue(ProjectSearchGlobs.includes("src/a.swift", globs: []))
        XCTAssertTrue(ProjectSearchGlobs.includes("src/a.swift", globs: ["*.swift"]))
        XCTAssertFalse(ProjectSearchGlobs.includes("src/a.ts", globs: ["*.swift"]))
        XCTAssertFalse(ProjectSearchGlobs.includes("OctetTests/aTests.swift", globs: ["*.swift", "!*Tests*"]))
        XCTAssertTrue(ProjectSearchGlobs.includes("src/deep/a.ts", globs: ["src/**/*.ts"]))
        XCTAssertFalse(ProjectSearchGlobs.includes("lib/a.ts", globs: ["src/**/*.ts"]))
        // A bare name means that folder anywhere.
        XCTAssertFalse(ProjectSearchGlobs.includes("web/vendor/x.js", globs: ["!vendor"]))
    }
}
