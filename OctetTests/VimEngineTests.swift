import XCTest
@testable import Octet

final class VimEngineTests: XCTestCase {
    private final class StringBuffer: VimBuffer {
        var storage = NSMutableString()
        var string: NSString { storage }
        var selection = NSRange(location: 0, length: 0)
        func replace(_ range: NSRange, with text: String) { storage.replaceCharacters(in: range, with: text) }
    }

    private struct Session {
        let buffer: StringBuffer
        let engine: VimEngine
        var saved = false
        var quit = false
    }

    /// `|` marks the caret in what's passed and in what's compared.
    private func make(_ marked: String) -> (VimEngine, StringBuffer) {
        let buffer = StringBuffer()
        let bar = (marked as NSString).range(of: "|")
        buffer.storage = NSMutableString(string: marked.replacingOccurrences(of: "|", with: ""))
        buffer.selection = NSRange(location: bar.location == NSNotFound ? 0 : bar.location, length: 0)
        return (VimEngine(buffer: buffer), buffer)
    }

    private func tokens(_ keys: String) -> [String] {
        var result: [String] = []
        var index = keys.startIndex
        while index < keys.endIndex {
            if keys[index] == "<", let close = keys[index...].firstIndex(of: ">"), keys.distance(from: index, to: close) > 1 {
                result.append(String(keys[index...close]))
                index = keys.index(after: close)
            } else {
                result.append(String(keys[index]))
                index = keys.index(after: index)
            }
        }
        return result
    }

    private func run(_ marked: String, _ keys: String) -> String {
        let (engine, buffer) = make(marked)
        return type(engine, buffer, keys)
    }

    @discardableResult
    private func type(_ engine: VimEngine, _ buffer: StringBuffer, _ keys: String) -> String {
        for key in tokens(keys) {
            if !engine.handle(key), engine.mode == .insert {
                // What the text view would do with a key Vim leaves alone.
                let at = buffer.selection.location
                switch key {
                case "<CR>": buffer.replace(NSRange(location: at, length: 0), with: "\n"); buffer.selection = NSRange(location: at + 1, length: 0)
                case "<BS>": if at > 0 { buffer.replace(NSRange(location: at - 1, length: 1), with: ""); buffer.selection = NSRange(location: at - 1, length: 0) }
                default:
                    buffer.replace(NSRange(location: at, length: 0), with: key)
                    buffer.selection = NSRange(location: at + 1, length: 0)
                }
            }
        }
        return shown(buffer)
    }

    private func shown(_ buffer: StringBuffer) -> String {
        let text = buffer.storage as String
        let caret = min(buffer.selection.location, (text as NSString).length)
        return (text as NSString).replacingCharacters(in: NSRange(location: caret, length: 0), with: "|")
    }

    // MARK: Deleting and changing

    func testDeleteCharacter() { XCTAssertEqual(run("hello |world", "x"), "hello |orld") }
    func testDeleteWord() { XCTAssertEqual(run("one |two three", "dw"), "one |three") }
    func testDeleteWordAtLineEndKeepsTheNewline() { XCTAssertEqual(run("a |b\nc", "dw"), "a| \nc") }
    func testChangeWord() { XCTAssertEqual(run("one |two three", "cwXX<Esc>"), "one X|X three") }
    func testChangeInnerWord() { XCTAssertEqual(run("foo ba|r baz", "ciwX<Esc>"), "foo |X baz") }
    func testDeleteInsideQuotes() { XCTAssertEqual(run("say \"he|llo\" now", "di\""), "say \"|\" now") }
    func testDeleteAroundParens() { XCTAssertEqual(run("f(a, |b) x", "da("), "f| x") }
    func testChangeInsideBraces() { XCTAssertEqual(run("if {a |b} c", "ci{Z<Esc>"), "if {|Z} c") }
    func testDeleteLine() { XCTAssertEqual(run("a\nb|b\nc", "dd"), "a\n|c") }
    func testDeleteLastLineMovesUp() { XCTAssertEqual(run("a\nb|b", "dd"), "|a") }
    func testCountedLines() { XCTAssertEqual(run("|a\nb\nc\nd", "2dd"), "|c\nd") }
    func testCountedWords() { XCTAssertEqual(run("|one two three four", "d2w"), "|three four") }
    func testDeleteToLineEnd() { XCTAssertEqual(run("ab|c d", "D"), "a|b") }
    func testChangeLine() { XCTAssertEqual(run("  a|b", "ccX<Esc>"), "|X") }
    func testDeleteThroughACharacter() { XCTAssertEqual(run("|a,b,c", "df,"), "|b,c") }
    func testDeleteUpToACharacter() { XCTAssertEqual(run("|abc,d", "dt,"), "|,d") }

    // MARK: Moving

    func testWordMotions() {
        XCTAssertEqual(run("|foo.bar baz", "w"), "foo|.bar baz")
        XCTAssertEqual(run("|foo.bar baz", "ww"), "foo.|bar baz")
        XCTAssertEqual(run("foo ba|r", "b"), "foo |bar")
        XCTAssertEqual(run("|foo bar", "e"), "fo|o bar")
        XCTAssertEqual(run("|foo.bar baz", "W"), "foo.bar |baz")
    }

    func testLineMotions() {
        XCTAssertEqual(run("abc|", "0"), "|abc")
        XCTAssertEqual(run("  a|b", "^"), "  |ab")
        XCTAssertEqual(run("|abc", "$"), "ab|c")
        XCTAssertEqual(run("a\nb\n|c", "gg"), "|a\nb\nc")
        XCTAssertEqual(run("|a\nb\nc", "G"), "a\nb\n|c")
        XCTAssertEqual(run("|a\nb\nc", "2G"), "a\n|b\nc")
    }

    func testVerticalMotionsKeepTheirColumn() {
        XCTAssertEqual(run("abcd|\nx\nabcdef", "jj"), "abcd\nx\nabc|def")
    }

    func testFindAndRepeat() {
        XCTAssertEqual(run("|a,b,c", "f,"), "a|,b,c")
        XCTAssertEqual(run("|a,b,c", "f,;"), "a,b|,c")
        XCTAssertEqual(run("a,b,c|", "F,"), "a,b|,c")
    }

    func testMatchingBracket() { XCTAssertEqual(run("(|a [b] c)", "%"), "(a [b|] c)") }

    func testParagraphs() { XCTAssertEqual(run("|a\nb\n\nc", "}"), "a\nb\n|\nc") }

    // MARK: Inserting

    func testInsertCommands() {
        XCTAssertEqual(run("a|b", "iX<Esc>"), "a|Xb")
        XCTAssertEqual(run("a|b", "aX<Esc>"), "abX".replacingOccurrences(of: "abX", with: "ab|X").replacingOccurrences(of: "ab|X", with: "a" + "b|X"))
        XCTAssertEqual(run("  a|b", "IX<Esc>"), "  |Xab")
        XCTAssertEqual(run("|ab", "AX<Esc>"), "ab|X")
        XCTAssertEqual(run("|a", "ob<Esc>"), "a\n|b")
        XCTAssertEqual(run("  |a", "Ob<Esc>"), "  |b\n  a")
    }

    // MARK: Yank and paste

    func testYankLineAndPaste() {
        XCTAssertEqual(run("one|\ntwo", "yyp"), "one\n|one\ntwo")
        XCTAssertEqual(run("one\ntw|o", "yyP"), "one\n|two\ntwo")
        XCTAssertEqual(run("one\ntw|o", "yyp"), "one\ntwo\n|two")
    }

    func testDeleteAndPasteCharacters() {
        XCTAssertEqual(run("|ab", "xp"), "b|a")
        XCTAssertEqual(run("foo |bar baz", "yiwwP"), "foo bar |barbaz".replacingOccurrences(of: "|barbaz", with: "ba|rbaz"))
    }

    // MARK: Small edits

    func testReplaceAndToggle() {
        XCTAssertEqual(run("|abc", "rx"), "|xbc")
        XCTAssertEqual(run("|abc", "2~"), "AB|c")
    }

    func testJoin() {
        XCTAssertEqual(run("a|\n  b", "J"), "a| b")
        XCTAssertEqual(run("a|\nb\nc", "3J"), "a b| c".replacingOccurrences(of: "b| c", with: "b| c"))
    }

    func testIndent() {
        XCTAssertEqual(run("|a\nb", ">>"), "    |a\nb")
        XCTAssertEqual(run("    |a\nb", "<<"), "|a\nb")
    }

    // MARK: Visual

    func testVisualDelete() {
        XCTAssertEqual(run("|one two", "ved"), "| two")
        XCTAssertEqual(run("|a\nb\nc", "Vjd"), "|c")
        XCTAssertEqual(run("|one two", "vlly"), "|one two")
    }

    func testVisualSelectionShowsInTheBuffer() {
        let (engine, buffer) = make("|one two")
        type(engine, buffer, "ve")
        XCTAssertEqual(buffer.selection, NSRange(location: 0, length: 3))
        XCTAssertEqual(engine.mode, .visual)
        type(engine, buffer, "<Esc>")
        XCTAssertEqual(engine.mode, .normal)
    }

    func testVisualTextObject() { XCTAssertEqual(run("foo ba|r baz", "viwd"), "foo | baz") }

    // MARK: Repeating

    func testDotRepeatsAnOperator() { XCTAssertEqual(run("|a b c d", "dw.."), "|d") }

    func testDotRepeatsAnInsert() { XCTAssertEqual(run("|x\ny", "Atest<Esc>j."), "xtest\nytes|t") }

    // MARK: Command line and search

    func testSubstitute() {
        XCTAssertEqual(run("|foo foo\nfoo", ":%s/foo/bar/g<CR>"), "|bar bar\nbar")
        XCTAssertEqual(run("|foo foo\nfoo", ":s/foo/x/<CR>"), "|x foo\nfoo")
    }

    func testGoToLine() { XCTAssertEqual(run("|a\nb\nc", ":3<CR>"), "a\nb\n|c") }

    func testSearch() {
        let (engine, buffer) = make("|a x a x a")
        XCTAssertEqual(type(engine, buffer, "/x<CR>"), "a |x a x a")
        XCTAssertEqual(type(engine, buffer, "n"), "a x a |x a")
        XCTAssertEqual(type(engine, buffer, "N"), "a |x a x a")
    }

    func testSaveAndQuit() {
        let (engine, buffer) = make("|a")
        var saved = 0, quit = 0
        engine.onSave = { saved += 1 }
        engine.onQuit = { quit += 1 }
        type(engine, buffer, ":w<CR>")
        XCTAssertEqual(saved, 1)
        type(engine, buffer, ":wq<CR>")
        XCTAssertEqual(saved, 2)
        XCTAssertEqual(quit, 1)
    }

    func testStatusLine() {
        let (engine, buffer) = make("|a")
        XCTAssertEqual(engine.status, "NORMAL")
        type(engine, buffer, "i")
        XCTAssertEqual(engine.status, "-- INSERT --")
        type(engine, buffer, "<Esc>:w")
        XCTAssertEqual(engine.status, ":w")
        type(engine, buffer, "<Esc>2d")
        XCTAssertEqual(engine.status, "2d")
    }
}
