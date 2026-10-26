import Foundation

/// What Vim's keys act on: text, a selection, and a way to replace a range.
/// A text view implements it for the editor; tests use a plain string.
protocol VimBuffer: AnyObject {
    var string: NSString { get }
    /// The caret when the length is 0; in Visual mode, the selected characters.
    var selection: NSRange { get set }
    func replace(_ range: NSRange, with text: String)
}

/// The part of Vim worth having in a text box: modes, counts, operators with
/// motions and text objects, registers, visual selections, searching, `.`
/// and a few `:` commands. It reads keys as strings (`"d"`, `"<Esc>"`,
/// `"<C-r>"`) and works on a `VimBuffer`, so it can be tested without a view.
final class VimEngine {
    enum Mode: Equatable { case normal, insert, visual, visualLine, command(Character) }

    private(set) var mode: Mode = .normal
    unowned var buffer: VimBuffer

    /// What the unnamed register holds: the last yank or delete.
    struct Register: Equatable {
        var text = ""
        var linewise = false
    }
    private(set) var register = Register()

    /// Keys typed so far of a command that isn't finished (`2d`, `"ay`).
    private(set) var pending: [String] = []
    /// The line being typed after `:`, `/` or `?`.
    private(set) var commandLine = ""
    /// A message for the status line: an error, a search that wrapped.
    private(set) var message = ""

    // Effects the host performs.
    var onSave: () -> Void = {}
    var onQuit: () -> Void = {}
    var onUndo: () -> Void = {}
    var onRedo: () -> Void = {}
    /// Lines per half page, set by the host from the view's height.
    var pageLines = 20

    private var head = 0
    private var anchor = 0
    /// The column `j` and `k` aim for.
    private var goalColumn: Int?
    private var lastFind: (kind: Character, char: Character)?
    private var lastSearch: (pattern: String, forward: Bool)?
    private var recording: [String] = []
    private var lastChange: [String] = []
    private var recordingInsert = false
    private var replaying = false
    private var lastSelection = NSRange(location: 0, length: 0)

    init(buffer: VimBuffer) {
        self.buffer = buffer
    }

    // MARK: Status

    /// The status line's words: the mode, a command being typed, or keys waiting.
    var status: String {
        switch mode {
        case .insert: return "-- INSERT --"
        case .visual: return "-- VISUAL --"
        case .visualLine: return "-- VISUAL LINE --"
        case .command(let prompt): return String(prompt) + commandLine
        case .normal: return pending.isEmpty ? (message.isEmpty ? "NORMAL" : message) : pending.joined()
        }
    }

    /// Whether the caret is drawn as a block over a character.
    var drawsBlockCaret: Bool { mode != .insert }

    /// Back to Normal, as when Vim mode is turned off and on.
    func reset() {
        mode = .normal
        pending = []
        commandLine = ""
        message = ""
        recording = []
        recordingInsert = false
    }

    // MARK: Keys

    private var text: NSString { buffer.string }
    private var length: Int { text.length }

    /// Handles a key. Returns whether it was used; in Insert mode, ordinary
    /// keys aren't (the text view types them), but are noted for `.`.
    @discardableResult
    func handle(_ key: String) -> Bool {
        message = ""
        switch mode {
        case .insert: return handleInsert(key)
        case .command: return handleCommandLine(key)
        case .visual, .visualLine: return handleVisual(key)
        case .normal: return handleNormal(key)
        }
    }

    // MARK: Insert

    private func handleInsert(_ key: String) -> Bool {
        if key == "<Esc>" || key == "<C-[>" || key == "<C-c>" {
            finishInsert()
            return true
        }
        if recordingInsert { recording.append(key) }
        guard replaying else { return false }
        // Replaying a change: the engine types for itself.
        let at = buffer.selection.location
        switch key {
        case "<CR>": buffer.replace(NSRange(location: at, length: 0), with: "\n"); buffer.selection = NSRange(location: at + 1, length: 0)
        case "<BS>":
            if at > 0 { buffer.replace(NSRange(location: at - 1, length: 1), with: ""); buffer.selection = NSRange(location: at - 1, length: 0) }
        case "<Tab>": buffer.replace(NSRange(location: at, length: 0), with: "\t"); buffer.selection = NSRange(location: at + 1, length: 0)
        default:
            if key.count == 1 || !key.hasPrefix("<") {
                buffer.replace(NSRange(location: at, length: 0), with: key)
                buffer.selection = NSRange(location: at + (key as NSString).length, length: 0)
            }
        }
        return true
    }

    private func finishInsert() {
        let caret = buffer.selection.location
        mode = .normal
        // Vim steps back onto the last character typed.
        head = (caret > lineStart(caret)) ? caret - 1 : caret
        setCaret(head)
        if recordingInsert {
            lastChange = recording
            recordingInsert = false
        }
    }

    private func enterInsert(at index: Int? = nil, keepRecording: Bool = true) {
        mode = .insert
        if let index { buffer.selection = NSRange(location: min(max(index, 0), length), length: 0) }
        if keepRecording, !replaying { recordingInsert = true }
    }

    // MARK: Normal

    private func handleNormal(_ key: String) -> Bool {
        clampToSelection()
        if key == "<Esc>" || key == "<C-[>" || key == "<C-c>" {
            pending = []
            recording = []
            return true
        }
        if pending.isEmpty { recording = [] }
        pending.append(key)
        recording.append(key)
        switch parse(pending) {
        case .incomplete:
            return true
        case .invalid:
            pending = []
            recording = []
            return true
        case .action(let action):
            pending = []
            let changed = perform(action)
            if changed, !recordingInsert, !replaying { lastChange = recording }
            if !recordingInsert { recording = [] }
            return true
        }
    }

    /// The caret follows a click or an arrow the text view handled itself.
    private func clampToSelection() {
        let selection = buffer.selection
        if selection != lastSelection || selection.length > 0 {
            head = selection.location
        }
        head = clampNormal(head)
    }

    // MARK: Parsing

    private enum Motion: Equatable {
        case left, right, up, down, lineStart, firstNonBlank, lineEnd
        case word(big: Bool), back(big: Bool), end(big: Bool)
        case find(kind: Character, char: Character), repeatFind(reverse: Bool)
        case match, paragraphForward, paragraphBack
        case fileStart, fileEnd, searchRepeat(reverse: Bool), searchWord(forward: Bool)
        case lineStartOfLine // `_`
    }

    private enum Object: Equatable {
        case word(big: Bool), quote(Character), bracket(open: Character, close: Character), paragraph
    }

    private enum Action: Equatable {
        case move(Motion, count: Int?)
        case operate(String, Motion, count: Int?)
        case operateObject(String, around: Bool, Object, count: Int?)
        case operateLines(String, count: Int?)
        case simple(String, arg: String?, count: Int?)
    }

    private enum Parsed: Equatable { case incomplete, invalid, action(Action) }

    private static let operators: Set<String> = ["d", "c", "y", "<", ">"]

    private func parse(_ keys: [String]) -> Parsed {
        var index = 0
        func count() -> Int? {
            var digits = ""
            while index < keys.count, let first = keys[index].first, keys[index].count == 1, first.isNumber,
                  !(digits.isEmpty && first == "0") {
                digits.append(first)
                index += 1
            }
            return digits.isEmpty ? nil : Int(digits)
        }
        let first = count()
        guard index < keys.count else { return .incomplete }
        let key = keys[index]
        index += 1
        if Self.operators.contains(key) {
            let second = count()
            guard index < keys.count else { return .incomplete }
            let target = keys[index]
            index += 1
            let total = first.map { $0 * (second ?? 1) } ?? second
            if target == key { return .action(.operateLines(key, count: total)) }
            if target == "i" || target == "a" {
                guard index < keys.count else { return .incomplete }
                let object = keys[index]
                guard let parsed = Self.object(object) else { return .invalid }
                return .action(.operateObject(key, around: target == "a", parsed, count: total))
            }
            switch motion(target, keys, &index) {
            case .none: return .invalid
            case .incomplete: return .incomplete
            case .some(let motion): return .action(.operate(key, motion, count: total))
            }
        }
        switch key {
        case "r":
            guard index < keys.count else { return .incomplete }
            return .action(.simple("r", arg: keys[index], count: first))
        case "g":
            guard index < keys.count else { return .incomplete }
            let next = keys[index]
            if next == "g" { return .action(.move(.fileStart, count: first)) }
            if next == "J" { return .action(.simple("gJ", arg: nil, count: first)) }
            return .invalid
        case "Z":
            guard index < keys.count else { return .incomplete }
            return keys[index] == "Z" ? .action(.simple("ZZ", arg: nil, count: first)) : .invalid
        default: break
        }
        switch motion(key, keys, &index) {
        case .some(let motion): return .action(.move(motion, count: first))
        case .incomplete: return .incomplete
        case .none: break
        }
        let simple: Set<String> = ["x", "X", "s", "S", "D", "C", "Y", "p", "P", "u", "<C-r>", ".", "i", "a", "I", "A", "o", "O",
                                   "v", "V", "J", "~", ":", "/", "?", "<C-d>", "<C-u>", "<C-v>"]
        return simple.contains(key) ? .action(.simple(key, arg: nil, count: first)) : .invalid
    }

    private enum MotionParse { case none, incomplete, some(Motion) }

    private func motion(_ key: String, _ keys: [String], _ index: inout Int) -> MotionParse {
        switch key {
        case "h", "<Left>", "<BS>": return .some(.left)
        case "l", "<Right>", " ": return .some(.right)
        case "j", "<Down>", "<C-n>": return .some(.down)
        case "k", "<Up>", "<C-p>": return .some(.up)
        case "0": return .some(.lineStart)
        case "^": return .some(.firstNonBlank)
        case "_": return .some(.lineStartOfLine)
        case "$": return .some(.lineEnd)
        case "w": return .some(.word(big: false))
        case "W": return .some(.word(big: true))
        case "b": return .some(.back(big: false))
        case "B": return .some(.back(big: true))
        case "e": return .some(.end(big: false))
        case "E": return .some(.end(big: true))
        case "%": return .some(.match)
        case "{": return .some(.paragraphBack)
        case "}": return .some(.paragraphForward)
        case "G": return .some(.fileEnd)
        case "n": return .some(.searchRepeat(reverse: false))
        case "N": return .some(.searchRepeat(reverse: true))
        case "*": return .some(.searchWord(forward: true))
        case "#": return .some(.searchWord(forward: false))
        case ";": return .some(.repeatFind(reverse: false))
        case ",": return .some(.repeatFind(reverse: true))
        case "f", "F", "t", "T":
            guard index < keys.count else { return .incomplete }
            let target = keys[index]
            index += 1
            guard target.count == 1, let char = target.first else { return .none }
            return .some(.find(kind: Character(key), char: char))
        case "g":
            guard index < keys.count else { return .incomplete }
            let next = keys[index]
            index += 1
            return next == "g" ? .some(.fileStart) : .none
        default: return .none
        }
    }

    private static func object(_ key: String) -> Object? {
        switch key {
        case "w": return .word(big: false)
        case "W": return .word(big: true)
        case "\"", "'", "`": return .quote(Character(key))
        case "(", ")", "b": return .bracket(open: "(", close: ")")
        case "[", "]": return .bracket(open: "[", close: "]")
        case "{", "}", "B": return .bracket(open: "{", close: "}")
        case "<", ">": return .bracket(open: "<", close: ">")
        case "p": return .paragraph
        default: return nil
        }
    }

    // MARK: Performing

    /// Runs an action; returns whether it changed the text (and so repeats with `.`).
    @discardableResult
    private func perform(_ action: Action) -> Bool {
        switch action {
        case .move(let motion, let count):
            if let target = evaluate(motion, count: count, operating: false) {
                head = clampNormal(target.index)
                if !isVertical(motion) { goalColumn = nil }
                setCaret(head)
            }
            return false
        case .operate(let op, let motion, let count):
            return operate(op, motion: motion, count: count)
        case .operateObject(let op, let around, let object, let count):
            guard let range = objectRange(object, around: around, count: count ?? 1) else { return false }
            return apply(op, range: range, linewise: object == .paragraph)
        case .operateLines(let op, let count):
            let line = lineRangeCovering(from: head, lines: count ?? 1)
            return apply(op, range: line, linewise: true)
        case .simple(let name, let arg, let count):
            return simple(name, arg: arg, count: count)
        }
    }

    private func isVertical(_ motion: Motion) -> Bool { motion == .up || motion == .down }

    private func operate(_ op: String, motion: Motion, count: Int?) -> Bool {
        var motion = motion
        // `cw` on a word changes to its end, as `ce` does.
        if op == "c", case .word(let big) = motion, !isSpace(at: head) { motion = .end(big: big) }
        guard let target = evaluate(motion, count: count, operating: true) else { return false }
        var start = head
        var end = target.index
        if end < start { swap(&start, &end) }
        if target.inclusive { end = min(end + 1, length) }
        // `dw` on the last word of a line stops at the line's end.
        if case .word = motion, op != "c", (count ?? 1) == 1, end > lineEnd(start), lineEnd(start) > start { end = lineEnd(start) }
        let range = NSRange(location: start, length: max(0, end - start))
        if target.linewise {
            let from = lineStart(min(start, end))
            let to = min(lineEnd(max(start, target.index == end ? end : end - 1)), length)
            return apply(op, range: NSRange(location: from, length: to - from), linewise: true)
        }
        return apply(op, range: range, linewise: false)
    }

    /// Applies an operator to a range. Linewise ranges are whole lines
    /// (without their final newline); the newline is handled here.
    private func apply(_ op: String, range raw: NSRange, linewise: Bool) -> Bool {
        var range = raw
        switch op {
        case "y":
            register = Register(text: yankText(range, linewise: linewise), linewise: linewise)
            head = clampNormal(linewise ? min(range.location, head) : range.location)
            setCaret(head)
            return false
        case "d":
            register = Register(text: yankText(range, linewise: linewise), linewise: linewise)
            if linewise { range = withNewline(range) }
            buffer.replace(range, with: "")
            head = clampNormal(min(range.location, length))
            if linewise { head = firstNonBlank(lineStart(min(range.location, max(length - 1, 0)))) }
            setCaret(head)
            return true
        case "c":
            register = Register(text: yankText(range, linewise: linewise), linewise: linewise)
            buffer.replace(range, with: "")
            enterInsert(at: range.location)
            return true
        case ">", "<":
            let lines = lineStarts(in: range)
            for start in lines.reversed() { shift(line: start, right: op == ">") }
            head = firstNonBlank(lineStart(min(range.location, max(length - 1, 0))))
            setCaret(head)
            return true
        default:
            return false
        }
    }

    private func yankText(_ range: NSRange, linewise: Bool) -> String {
        let piece = text.substring(with: range)
        return linewise ? piece + "\n" : piece
    }

    /// A line range extended over the newline that ends it (or, at the end
    /// of the text, the one before it).
    private func withNewline(_ range: NSRange) -> NSRange {
        let end = NSMaxRange(range)
        if end < length { return NSRange(location: range.location, length: range.length + 1) }
        if range.location > 0 { return NSRange(location: range.location - 1, length: range.length + 1) }
        return range
    }

    private func shift(line start: Int, right: Bool) {
        if right {
            if lineEnd(start) > start { buffer.replace(NSRange(location: start, length: 0), with: "    ") }
            return
        }
        var removable = 0
        while removable < 4, start + removable < length, text.character(at: start + removable) == 32 { removable += 1 }
        if removable == 0, start < length, text.character(at: start) == 9 { removable = 1 }
        if removable > 0 { buffer.replace(NSRange(location: start, length: removable), with: "") }
    }

    private func lineStarts(in range: NSRange) -> [Int] {
        var starts: [Int] = []
        var at = lineStart(range.location)
        let end = max(NSMaxRange(range), range.location)
        while at <= end, at <= length {
            starts.append(at)
            let next = lineEnd(at) + 1
            if next > length || next > end { break }
            at = next
        }
        return starts
    }

    // MARK: Simple commands

    private func simple(_ name: String, arg: String?, count: Int?) -> Bool {
        let n = count ?? 1
        switch name {
        case "i": enterInsert(at: head)
        case "a": enterInsert(at: lineEnd(head) > head ? head + 1 : head)
        case "I": enterInsert(at: firstNonBlank(lineStart(head)))
        case "A": enterInsert(at: lineEnd(head))
        case "o":
            let indent = leadingWhitespace(of: lineStart(head))
            let end = lineEnd(head)
            buffer.replace(NSRange(location: end, length: 0), with: "\n" + indent)
            enterInsert(at: end + 1 + (indent as NSString).length)
            return true
        case "O":
            let start = lineStart(head)
            let indent = leadingWhitespace(of: start)
            buffer.replace(NSRange(location: start, length: 0), with: indent + "\n")
            enterInsert(at: start + (indent as NSString).length)
            return true
        case "x":
            let end = min(head + n, lineEnd(head))
            guard end > head else { return false }
            _ = apply("d", range: NSRange(location: head, length: end - head), linewise: false)
            return true
        case "X":
            let start = max(head - n, lineStart(head))
            guard start < head else { return false }
            _ = apply("d", range: NSRange(location: start, length: head - start), linewise: false)
            return true
        case "s":
            let end = min(head + n, lineEnd(head))
            return apply("c", range: NSRange(location: head, length: max(0, end - head)), linewise: false)
        case "S":
            return apply("c", range: lineRangeCovering(from: head, lines: n), linewise: true)
        case "D":
            return apply("d", range: NSRange(location: head, length: lineEnd(head) - head), linewise: false)
        case "C":
            return apply("c", range: NSRange(location: head, length: lineEnd(head) - head), linewise: false)
        case "Y":
            _ = apply("y", range: lineRangeCovering(from: head, lines: n), linewise: true)
            return false
        case "r":
            guard let arg, arg.count == 1, head + n <= lineEnd(head) else { return false }
            buffer.replace(NSRange(location: head, length: n), with: String(repeating: arg, count: n))
            head += n - 1
            setCaret(head)
            return true
        case "J", "gJ":
            return join(lines: max(n, 2), spaced: name == "J")
        case "~":
            let end = min(head + n, lineEnd(head))
            guard end > head else { return false }
            let range = NSRange(location: head, length: end - head)
            buffer.replace(range, with: Self.toggled(text.substring(with: range)))
            head = clampNormal(end)
            setCaret(head)
            return true
        case "p", "P":
            return paste(before: name == "P", count: n)
        case "u": onUndo(); head = clampNormal(buffer.selection.location); return false
        case "<C-r>": onRedo(); head = clampNormal(buffer.selection.location); return false
        case ".": repeatLast(); return false
        case "v": enterVisual(.visual)
        case "V": enterVisual(.visualLine)
        case "<C-v>": enterVisual(.visual)
        case ":": startCommandLine(":")
        case "/": startCommandLine("/")
        case "?": startCommandLine("?")
        case "<C-d>": scroll(lines: pageLines / 2)
        case "<C-u>": scroll(lines: -(pageLines / 2))
        case "ZZ": onSave(); onQuit()
        default: break
        }
        return false
    }

    private func scroll(lines: Int) {
        var index = head
        for _ in 0..<abs(lines) { index = lines > 0 ? nextLineStart(index) ?? lineStart(index) : previousLineStart(index) ?? lineStart(index) }
        head = clampNormal(columnTarget(on: index, column: goalColumn ?? head - lineStart(head)))
        setCaret(head)
    }

    private func repeatLast() {
        guard !lastChange.isEmpty else { return }
        let keys = lastChange
        replaying = true
        let saved = lastChange
        for key in keys { handle(key) }
        // A change that ends in Insert is finished by its own Esc.
        if mode == .insert { finishInsert() }
        replaying = false
        lastChange = saved
    }

    private func join(lines: Int, spaced: Bool) -> Bool {
        var joined = false
        for _ in 0..<(lines - 1) {
            let end = lineEnd(head)
            guard end < length else { break }
            var next = end + 1
            var trimmed = next
            if spaced {
                while trimmed < length, text.character(at: trimmed) == 32 || text.character(at: trimmed) == 9 { trimmed += 1 }
            } else { trimmed = next }
            let beforeIsBlank = end == lineStart(head)
            let nextIsEmpty = trimmed >= length || text.character(at: trimmed) == 10
            let glue = (spaced && !beforeIsBlank && !nextIsEmpty) ? " " : ""
            buffer.replace(NSRange(location: end, length: trimmed - end), with: glue)
            head = end
            next = 0
            joined = true
        }
        head = clampNormal(head)
        setCaret(head)
        return joined
    }

    private func paste(before: Bool, count: Int) -> Bool {
        guard !register.text.isEmpty else { return false }
        let piece = String(repeating: register.text, count: count)
        if register.linewise {
            let atLine = before ? lineStart(head) : min(lineEnd(head) + 1, length)
            var insert = piece
            var location = atLine
            // Below the last line, which has no newline of its own.
            if !before, lineEnd(head) >= length {
                insert = "\n" + String(piece.dropLast())
                location = length
                buffer.replace(NSRange(location: location, length: 0), with: insert)
                head = firstNonBlank(location + 1)
            } else {
                buffer.replace(NSRange(location: location, length: 0), with: insert)
                head = firstNonBlank(location)
            }
            setCaret(head)
            return true
        }
        let at = before || lineEnd(head) == head ? head : head + 1
        buffer.replace(NSRange(location: at, length: 0), with: piece)
        head = clampNormal(at + (piece as NSString).length - 1)
        setCaret(head)
        return true
    }

    // MARK: Visual

    private func enterVisual(_ visual: Mode) {
        mode = visual
        anchor = head
        showVisual()
    }

    private func showVisual() {
        if mode == .visualLine {
            let from = lineStart(min(anchor, head))
            let to = lineEnd(max(anchor, head))
            buffer.selection = NSRange(location: from, length: max(to - from, 0))
        } else {
            let from = min(anchor, head)
            let to = min(max(anchor, head) + 1, length)
            buffer.selection = NSRange(location: from, length: max(to - from, 0))
        }
        lastSelection = buffer.selection
    }

    private func handleVisual(_ key: String) -> Bool {
        if key == "<Esc>" || key == "<C-[>" || key == "<C-c>" {
            pending = []
            exitVisual()
            return true
        }
        // A click that moved the selection ends the mode.
        if buffer.selection != lastSelection { exitVisual() ; return handleNormal(key) }
        // `r` takes the next key; the rest act on the selection at once.
        if pending == ["r"] {
            pending = []
            visualCommand("r", arg: key)
            return true
        }
        if pending.isEmpty {
            if key == "r" { pending = ["r"]; return true }
            let acting: Set<String> = ["d", "x", "X", "D", "y", "Y", "c", "s", "S", ">", "<", "J", "~", "u", "U", "p", "P", "o", "O", "v", "V", ":"]
            if acting.contains(key) { visualCommand(key, arg: nil); return true }
        }
        pending.append(key)
        let keys = pending
        // Text objects extend the selection.
        if keys.count >= 2, keys[keys.count - 2] == "i" || keys[keys.count - 2] == "a" {
            pending = []
            if let object = Self.object(key), let range = objectRange(object, around: keys[keys.count - 2] == "a", count: 1), range.length > 0 {
                anchor = range.location
                head = NSMaxRange(range) - 1
                showVisual()
            }
            return true
        }
        if keys == ["i"] || keys == ["a"] { return true }
        switch parse(keys) {
        case .incomplete: return true
        case .invalid: pending = []; return true
        case .action(let action):
            pending = []
            performVisual(action)
            return true
        }
    }

    private func performVisual(_ action: Action) {
        switch action {
        case .move(let motion, let count):
            if let target = evaluate(motion, count: count, operating: false) {
                head = min(max(target.index, 0), max(length - 1, 0))
                if !isVertical(motion) { goalColumn = nil }
                showVisual()
            }
        case .operate, .operateObject, .operateLines:
            break
        case .simple(let name, let arg, _):
            visualCommand(name, arg: arg)
        }
    }

    private func visualRange() -> (range: NSRange, linewise: Bool) {
        if mode == .visualLine {
            let from = lineStart(min(anchor, head))
            let to = lineEnd(max(anchor, head))
            return (NSRange(location: from, length: to - from), true)
        }
        let from = min(anchor, head)
        let to = min(max(anchor, head) + 1, length)
        return (NSRange(location: from, length: to - from), false)
    }

    private func visualCommand(_ name: String, arg: String?) {
        let (range, linewise) = visualRange()
        switch name {
        case "d", "x", "X", "D":
            exitVisual(keepCaret: true)
            _ = apply("d", range: range, linewise: linewise || name == "X" || name == "D")
        case "y", "Y":
            exitVisual(keepCaret: true)
            _ = apply("y", range: range, linewise: linewise || name == "Y")
            head = clampNormal(range.location)
            setCaret(head)
        case "c", "s", "S":
            exitVisual(keepCaret: true)
            _ = apply("c", range: range, linewise: linewise || name == "S")
        case ">", "<":
            exitVisual(keepCaret: true)
            _ = apply(name, range: range, linewise: true)
        case "J":
            exitVisual(keepCaret: true)
            head = lineStart(range.location)
            _ = join(lines: max(2, lineStarts(in: range).count), spaced: true)
        case "~", "u", "U":
            exitVisual(keepCaret: true)
            let piece = text.substring(with: range)
            let changed = name == "u" ? piece.lowercased() : name == "U" ? piece.uppercased() : Self.toggled(piece)
            buffer.replace(range, with: changed)
            head = clampNormal(range.location)
            setCaret(head)
        case "r":
            guard let arg, arg.count == 1 else { return }
            exitVisual(keepCaret: true)
            let piece = text.substring(with: range)
            buffer.replace(range, with: String(piece.map { $0 == "\n" ? "\n" : Character(arg) }))
            head = clampNormal(range.location)
            setCaret(head)
        case "p", "P":
            // The selection is replaced by the register, which the delete
            // would otherwise take over.
            let held = register
            let wasLast = NSMaxRange(range) >= length
            let wasAtLineEnd = !linewise && NSMaxRange(range) >= lineEnd(range.location)
            exitVisual(keepCaret: true)
            _ = apply("d", range: range, linewise: linewise)
            register = held
            _ = paste(before: linewise ? !wasLast : !wasAtLineEnd, count: 1)
        case "o", "O":
            swap(&anchor, &head)
            showVisual()
        case "v": mode == .visual ? exitVisual() : { mode = .visual; showVisual() }()
        case "V": mode == .visualLine ? exitVisual() : { mode = .visualLine; showVisual() }()
        case ":":
            exitVisual()
            startCommandLine(":")
        default: break
        }
    }

    private func exitVisual(keepCaret: Bool = false) {
        mode = .normal
        if !keepCaret { head = clampNormal(head) }
        setCaret(head)
    }

    // MARK: The command line

    private func startCommandLine(_ prompt: Character) {
        mode = .command(prompt)
        commandLine = ""
    }

    private func handleCommandLine(_ key: String) -> Bool {
        guard case .command(let prompt) = mode else { return false }
        switch key {
        case "<Esc>", "<C-c>", "<C-[>":
            mode = .normal
        case "<BS>":
            if commandLine.isEmpty { mode = .normal } else { commandLine.removeLast() }
        case "<CR>":
            let line = commandLine
            mode = .normal
            commandLine = ""
            if prompt == ":" { runCommand(line) } else { search(for: line, forward: prompt == "/") }
        default:
            if key.count == 1 || !key.hasPrefix("<") { commandLine += key }
        }
        return true
    }

    private func runCommand(_ raw: String) {
        let line = raw.trimmingCharacters(in: .whitespaces)
        if line.isEmpty { return }
        if let number = Int(line) {
            goTo(line: number)
            return
        }
        switch line {
        case "w": onSave(); message = "Saved"
        case "q", "q!": onQuit()
        case "wq", "x", "wq!": onSave(); onQuit()
        case "noh", "nohlsearch": break
        default:
            if line.hasPrefix("s/") || line.hasPrefix("%s/") { substitute(line) }
            else { message = "Not an editor command: \(line)" }
        }
    }

    private func goTo(line number: Int) {
        var index = 0
        var current = 1
        while current < number, let next = nextLineStart(index) { index = next; current += 1 }
        head = firstNonBlank(lineStart(index))
        setCaret(head)
    }

    /// `:s/old/new/` on the current line, `:%s/old/new/g` on every line.
    private func substitute(_ line: String) {
        let wholeFile = line.hasPrefix("%")
        let body = wholeFile ? String(line.dropFirst(3)) : String(line.dropFirst(2))
        var parts: [String] = []
        var current = ""
        var escaped = false
        for character in body {
            if escaped { current.append(character); escaped = false }
            else if character == "\\" { escaped = true; current.append(character) }
            else if character == "/" { parts.append(current); current = "" }
            else { current.append(character) }
        }
        parts.append(current)
        guard parts.count >= 2, !parts[0].isEmpty else { message = "Bad substitute"; return }
        let global = parts.count > 2 && parts[2].contains("g")
        guard let regex = try? NSRegularExpression(pattern: parts[0]) else { message = "Bad pattern"; return }
        let scope = wholeFile ? NSRange(location: 0, length: length)
            : NSRange(location: lineStart(head), length: lineEnd(head) - lineStart(head))
        let original = text.substring(with: scope)
        var changedText = ""
        var changes = 0
        var lines = original.components(separatedBy: "\n")
        for (offset, piece) in lines.enumerated() {
            let whole = NSRange(location: 0, length: (piece as NSString).length)
            guard regex.firstMatch(in: piece, range: whole) != nil else { continue }
            let replaced: String
            if global {
                replaced = regex.stringByReplacingMatches(in: piece, range: whole, withTemplate: parts[1])
            } else if let first = regex.firstMatch(in: piece, range: whole) {
                replaced = (piece as NSString).replacingCharacters(in: first.range, with: regex.replacementString(for: first, in: piece, offset: 0, template: parts[1]))
            } else { replaced = piece }
            lines[offset] = replaced
            changes += 1
        }
        changedText = lines.joined(separator: "\n")
        guard changes > 0 else { message = "Pattern not found: \(parts[0])"; return }
        buffer.replace(scope, with: changedText)
        message = "\(changes) line\(changes == 1 ? "" : "s") changed"
        head = clampNormal(head)
        setCaret(head)
    }

    // MARK: Searching

    private func search(for pattern: String, forward: Bool) {
        guard !pattern.isEmpty else { return }
        lastSearch = (pattern, forward)
        jumpToSearch(reverse: false)
    }

    private func findMatch(_ pattern: String, forward: Bool, from index: Int) -> Int? {
        let options: NSString.CompareOptions = forward ? [] : [.backwards]
        if forward {
            let start = min(index + 1, length)
            let found = text.range(of: pattern, options: options, range: NSRange(location: start, length: length - start))
            if found.location != NSNotFound { return found.location }
            let wrapped = text.range(of: pattern, options: options, range: NSRange(location: 0, length: length))
            if wrapped.location != NSNotFound { message = "search hit BOTTOM, continuing at TOP"; return wrapped.location }
        } else {
            let found = text.range(of: pattern, options: options, range: NSRange(location: 0, length: max(index, 0)))
            if found.location != NSNotFound { return found.location }
            let wrapped = text.range(of: pattern, options: options, range: NSRange(location: 0, length: length))
            if wrapped.location != NSNotFound { message = "search hit TOP, continuing at BOTTOM"; return wrapped.location }
        }
        message = "Pattern not found: \(pattern)"
        return nil
    }

    private func jumpToSearch(reverse: Bool) {
        guard let last = lastSearch else { return }
        let forward = reverse ? !last.forward : last.forward
        if let found = findMatch(last.pattern, forward: forward, from: head) {
            head = clampNormal(found)
            setCaret(head)
        }
    }

    // MARK: Motions

    private struct Target {
        var index: Int
        var inclusive = false
        var linewise = false
    }

    private func evaluate(_ motion: Motion, count: Int?, operating: Bool) -> Target? {
        let n = count ?? 1
        switch motion {
        case .left:
            return Target(index: max(head - n, lineStart(head)))
        case .right:
            let limit = operating ? lineEnd(head) : max(lineEnd(head) - 1, lineStart(head))
            return Target(index: min(head + n, limit))
        case .up, .down:
            var index = head
            for _ in 0..<n {
                guard let next = (motion == .down ? nextLineStart(index) : previousLineStart(index)) else {
                    if operating { return nil }
                    break
                }
                index = next
            }
            let column = goalColumn ?? (head - lineStart(head))
            goalColumn = column
            return Target(index: columnTarget(on: index, column: column), linewise: true)
        case .lineStart: return Target(index: lineStart(head))
        case .firstNonBlank, .lineStartOfLine: return Target(index: firstNonBlank(lineStart(head)))
        case .lineEnd:
            var index = head
            for _ in 1..<max(n, 1) { index = nextLineStart(index) ?? index }
            let end = lineEnd(index)
            return Target(index: operating ? end : max(end - 1, lineStart(index)), inclusive: false)
        case .word(let big): return Target(index: stepWords(forward: true, count: n, big: big, to: .start))
        case .back(let big): return Target(index: stepWords(forward: false, count: n, big: big, to: .start))
        case .end(let big): return Target(index: stepWords(forward: true, count: n, big: big, to: .end), inclusive: true)
        case .find(let kind, let char):
            lastFind = (kind, char)
            return findChar(kind: kind, char: char, count: n).map { Target(index: $0, inclusive: kind == "f" || kind == "t") }
        case .repeatFind(let reverse):
            guard let last = lastFind else { return nil }
            var kind = last.kind
            if reverse { kind = kind.isLowercase ? Character(kind.uppercased()) : Character(kind.lowercased()) }
            return findChar(kind: kind, char: last.char, count: n, repeating: true).map { Target(index: $0, inclusive: kind == "f" || kind == "t") }
        case .match: return matchingBracket().map { Target(index: $0, inclusive: true) }
        case .paragraphForward: return Target(index: paragraph(forward: true, count: n))
        case .paragraphBack: return Target(index: paragraph(forward: false, count: n))
        case .fileStart:
            return Target(index: firstNonBlank(count.map { lineIndex($0) } ?? 0), linewise: true)
        case .fileEnd:
            let index = count.map { lineIndex($0) } ?? lastLineStart()
            return Target(index: firstNonBlank(index), linewise: true)
        case .searchRepeat(let reverse):
            guard let last = lastSearch else { return nil }
            let forward = reverse ? !last.forward : last.forward
            return findMatch(last.pattern, forward: forward, from: head).map { Target(index: $0) }
        case .searchWord(let forward):
            guard let word = wordUnderCaret() else { return nil }
            lastSearch = (word, forward)
            return findMatch(word, forward: forward, from: forward ? head : lineStart(head) == head ? head : head).map { Target(index: $0) }
        }
    }

    private enum WordEdge { case start, end }

    private func klass(at index: Int, big: Bool) -> Int {
        guard index >= 0, index < length else { return 0 }
        let c = text.character(at: index)
        if c == 32 || c == 9 || c == 10 || c == 13 { return 0 }
        if big { return 1 }
        guard let scalar = Unicode.Scalar(c) else { return 1 }
        let character = Character(scalar)
        return character.isLetter || character.isNumber || character == "_" ? 1 : 2
    }

    private func stepWords(forward: Bool, count: Int, big: Bool, to edge: WordEdge) -> Int {
        var i = head
        for _ in 0..<max(count, 1) {
            if forward, edge == .start {
                let cls = klass(at: i, big: big)
                if cls != 0 { while i < length, klass(at: i, big: big) == cls { i += 1 } }
                while i < length, klass(at: i, big: big) == 0 {
                    // An empty line is a word of its own.
                    if text.character(at: i) == 10, i > 0, text.character(at: i - 1) == 10 { break }
                    i += 1
                }
            } else if forward {
                i = min(i + 1, length)
                while i < length, klass(at: i, big: big) == 0 { i += 1 }
                let cls = klass(at: i, big: big)
                while i + 1 < length, klass(at: i + 1, big: big) == cls, cls != 0 { i += 1 }
            } else {
                i = max(i - 1, 0)
                while i > 0, klass(at: i, big: big) == 0 {
                    if text.character(at: i) == 10, text.character(at: i - 1) == 10 { break }
                    i -= 1
                }
                let cls = klass(at: i, big: big)
                while i > 0, klass(at: i - 1, big: big) == cls, cls != 0 { i -= 1 }
            }
        }
        return min(i, length)
    }

    private func findChar(kind: Character, char: Character, count: Int, repeating: Bool = false) -> Int? {
        let start = lineStart(head)
        let end = lineEnd(head)
        let target = String(char) as NSString
        var index = head
        for step in 0..<max(count, 1) {
            switch kind {
            case "f", "t":
                var from = index + 1
                // Repeating `t` must not stay put on the character before.
                if kind == "t", repeating, step == 0, from < end, text.substring(with: NSRange(location: from, length: 1)) == target as String { from += 1 }
                guard from <= end else { return nil }
                let found = text.range(of: target as String, options: [], range: NSRange(location: from, length: end - from))
                guard found.location != NSNotFound else { return nil }
                index = found.location
            default:
                var upTo = index
                if kind == "T", repeating, step == 0, upTo > start, text.substring(with: NSRange(location: upTo - 1, length: 1)) == target as String { upTo -= 1 }
                guard upTo > start else { return nil }
                let found = text.range(of: target as String, options: [.backwards], range: NSRange(location: start, length: upTo - start))
                guard found.location != NSNotFound else { return nil }
                index = found.location
            }
        }
        return kind == "t" ? index - 1 : kind == "T" ? index + 1 : index
    }

    private func matchingBracket() -> Int? {
        let pairs: [(Character, Character)] = [("(", ")"), ("[", "]"), ("{", "}")]
        var index = head
        let end = lineEnd(head)
        var found: (Character, Character, Bool)?
        while index < end {
            let c = Character(Unicode.Scalar(text.character(at: index)) ?? " ")
            if let pair = pairs.first(where: { $0.0 == c }) { found = (pair.0, pair.1, true); break }
            if let pair = pairs.first(where: { $0.1 == c }) { found = (pair.0, pair.1, false); break }
            index += 1
        }
        guard let (open, close, forward) = found else { return nil }
        var depth = 0
        var i = index
        while i >= 0, i < length {
            let c = Character(Unicode.Scalar(text.character(at: i)) ?? " ")
            if c == (forward ? open : close) { depth += 1 }
            else if c == (forward ? close : open) { depth -= 1; if depth == 0 { return i } }
            i += forward ? 1 : -1
        }
        return nil
    }

    private func paragraph(forward: Bool, count: Int) -> Int {
        var index = lineStart(head)
        for _ in 0..<max(count, 1) {
            if forward {
                while index < length, isBlankLine(at: index) { index = nextLineStart(index) ?? length }
                while index < length, !isBlankLine(at: index) { index = nextLineStart(index) ?? length }
            } else {
                while index > 0, isBlankLine(at: index) { index = previousLineStart(index) ?? 0 }
                while index > 0, !isBlankLine(at: index) { index = previousLineStart(index) ?? 0 }
            }
        }
        return min(index, length)
    }

    private func isBlankLine(at index: Int) -> Bool {
        let start = lineStart(index)
        let end = lineEnd(index)
        return end == start || text.substring(with: NSRange(location: start, length: end - start)).trimmingCharacters(in: .whitespaces).isEmpty
    }

    private func wordUnderCaret() -> String? {
        var start = head
        var end = head
        guard klass(at: head, big: false) == 1 else { return nil }
        while start > 0, klass(at: start - 1, big: false) == 1 { start -= 1 }
        while end < length, klass(at: end, big: false) == 1 { end += 1 }
        return text.substring(with: NSRange(location: start, length: end - start))
    }

    // MARK: Text objects

    private func objectRange(_ object: Object, around: Bool, count: Int) -> NSRange? {
        switch object {
        case .word(let big):
            var start = head
            var end = head
            let cls = klass(at: head, big: big)
            while start > lineStart(head), klass(at: start - 1, big: big) == cls { start -= 1 }
            while end < lineEnd(head), klass(at: end, big: big) == cls { end += 1 }
            if around {
                var trailing = end
                while trailing < lineEnd(head), klass(at: trailing, big: big) == 0 { trailing += 1 }
                if trailing > end { end = trailing }
                else {
                    while start > lineStart(head), klass(at: start - 1, big: big) == 0 { start -= 1 }
                }
            }
            return NSRange(location: start, length: end - start)
        case .quote(let quote):
            let start = lineStart(head)
            let end = lineEnd(head)
            var positions: [Int] = []
            var index = start
            while index < end {
                if text.character(at: index) == quote.asciiValue.map(UInt16.init), index == start || text.character(at: index - 1) != 92 { positions.append(index) }
                index += 1
            }
            var pair: (Int, Int)?
            var i = 0
            while i + 1 < positions.count {
                if positions[i] <= head, head <= positions[i + 1] { pair = (positions[i], positions[i + 1]); break }
                if positions[i] > head { pair = (positions[i], positions[i + 1]); break }
                i += 2
            }
            guard let (open, close) = pair else { return nil }
            return around ? NSRange(location: open, length: close - open + 1) : NSRange(location: open + 1, length: close - open - 1)
        case .bracket(let open, let close):
            var depth = 0
            var left: Int?
            var i = head
            if Character(Unicode.Scalar(text.character(at: min(head, max(length - 1, 0)))) ?? " ") == open { left = head }
            else {
                while i >= 0 {
                    let c = Character(Unicode.Scalar(text.character(at: i)) ?? " ")
                    if c == close, i != head { depth += 1 }
                    else if c == open { if depth == 0 { left = i; break }; depth -= 1 }
                    i -= 1
                }
            }
            guard let left else { return nil }
            depth = 0
            var right: Int?
            i = left
            while i < length {
                let c = Character(Unicode.Scalar(text.character(at: i)) ?? " ")
                if c == open { depth += 1 }
                else if c == close { depth -= 1; if depth == 0 { right = i; break } }
                i += 1
            }
            guard let right else { return nil }
            return around ? NSRange(location: left, length: right - left + 1) : NSRange(location: left + 1, length: right - left - 1)
        case .paragraph:
            var start = lineStart(head)
            var end = lineEnd(head)
            let blank = isBlankLine(at: head)
            while start > 0, let previous = previousLineStart(start), isBlankLine(at: previous) == blank { start = previous }
            while let next = nextLineStart(end), isBlankLine(at: next) == blank { end = lineEnd(next) }
            if around, let next = nextLineStart(end), isBlankLine(at: next) != blank {
                var trailing = next
                end = lineEnd(trailing)
                while let more = nextLineStart(trailing), isBlankLine(at: more) == !blank { trailing = more; end = lineEnd(more) }
            }
            return NSRange(location: start, length: max(end - start, 0))
        }
    }

    // MARK: Text helpers

    private func lineStart(_ index: Int) -> Int {
        let i = min(max(index, 0), length)
        guard i > 0 else { return 0 }
        let found = text.range(of: "\n", options: .backwards, range: NSRange(location: 0, length: i))
        return found.location == NSNotFound ? 0 : found.location + 1
    }

    private func lineEnd(_ index: Int) -> Int {
        let i = min(max(index, 0), length)
        let found = text.range(of: "\n", options: [], range: NSRange(location: i, length: length - i))
        return found.location == NSNotFound ? length : found.location
    }

    private func nextLineStart(_ index: Int) -> Int? {
        let end = lineEnd(index)
        return end < length ? end + 1 : nil
    }

    private func previousLineStart(_ index: Int) -> Int? {
        let start = lineStart(index)
        return start > 0 ? lineStart(start - 1) : nil
    }

    private func lastLineStart() -> Int { lineStart(length) == length && length > 0 && text.character(at: length - 1) == 10 ? lineStart(length - 1) : lineStart(length) }

    private func lineIndex(_ number: Int) -> Int {
        var index = 0
        var current = 1
        while current < number, let next = nextLineStart(index) { index = next; current += 1 }
        return index
    }

    private func firstNonBlank(_ lineStart: Int) -> Int {
        let end = lineEnd(lineStart)
        var i = lineStart
        while i < end, text.character(at: i) == 32 || text.character(at: i) == 9 { i += 1 }
        return i < end ? i : max(end - 1, lineStart)
    }

    private func leadingWhitespace(of lineStart: Int) -> String {
        let end = lineEnd(lineStart)
        var i = lineStart
        while i < end, text.character(at: i) == 32 || text.character(at: i) == 9 { i += 1 }
        return text.substring(with: NSRange(location: lineStart, length: i - lineStart))
    }

    private func columnTarget(on lineStart: Int, column: Int) -> Int {
        let end = lineEnd(lineStart)
        return min(lineStart + column, max(end - 1, lineStart))
    }

    private func lineRangeCovering(from index: Int, lines: Int) -> NSRange {
        let start = lineStart(index)
        var end = lineEnd(index)
        for _ in 1..<max(lines, 1) { guard let next = nextLineStart(end) else { break }; end = lineEnd(next) }
        return NSRange(location: start, length: end - start)
    }

    private func isSpace(at index: Int) -> Bool { klass(at: index, big: false) == 0 }

    /// In Normal mode the caret sits on a character, not past the last one.
    private func clampNormal(_ index: Int) -> Int {
        let clamped = min(max(index, 0), length)
        let end = lineEnd(clamped)
        let start = lineStart(clamped)
        return clamped >= end ? max(end - 1, start) : clamped
    }

    private func setCaret(_ index: Int) {
        buffer.selection = NSRange(location: index, length: 0)
        lastSelection = buffer.selection
    }

    private static func toggled(_ string: String) -> String {
        String(string.map { character -> Character in
            let upper = character.uppercased(), lower = character.lowercased()
            return String(character) == upper ? Character(lower.first.map(String.init) ?? String(character)) : Character(upper.first.map(String.init) ?? String(character))
        })
    }
}

