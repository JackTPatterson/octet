import Foundation

/// Colours a command line the way a shell reads it. Octet renders the input
/// itself while a pane sits at a prompt, so highlighting is Octet's to do
/// rather than something the shell has to be configured for.
enum ShellSyntax {
    enum Role: Equatable {
        case command
        case builtin
        case argument
        case flag
        case string
        case path
        case variable
        case assignment
        case reserved
        case expansion
        case glob
        case redirect
        case separator
        case comment
    }

    struct Span: Equatable {
        let range: Range<String.Index>
        let role: Role
    }

    /// Commands the shell handles itself; worth distinguishing from programs.
    static let builtins: Set<String> = [
        "cd", "export", "alias", "unalias", "source", ".", "set", "unset", "echo", "exit", "eval",
        "exec", "return", "shift", "test", "read", "pushd", "popd", "dirs", "jobs", "fg", "bg",
        "kill", "wait", "type", "which", "hash", "history", "umask", "trap", "let", "local",
        "declare", "typeset", "readonly", "printf", "pwd", "true", "false", "command", "builtin",
    ]

    /// Tokens after which the next word is a command again.
    private static let commandResets: Set<String> = ["|", "||", "&&", ";", "&", "|&", "(", "{", "!"]
    private static let reserved: Set<String> = [
        "if", "then", "else", "elif", "fi", "for", "while", "until", "do", "done",
        "case", "esac", "function", "select", "repeat", "in"
    ]
    /// zsh-syntax-highlighting calls these precommands: they modify the next
    /// command rather than consuming command position themselves.
    /// After these, `NAME=value` words are still assignments.
    private static let declarers: Set<String> = ["export", "local", "declare", "typeset", "readonly", "set"]
    private static let precommands: Set<String> = ["sudo", "env", "command", "builtin", "noglob", "time", "xargs"]

    static func spans(in line: String) -> [Span] {
        var spans: [Span] = []
        var index = line.startIndex
        var expectingCommand = true
        var afterRedirection = false
        var declaring = false

        while index < line.endIndex {
            let character = line[index]
            if character == " " || character == "\t" {
                index = line.index(after: index)
                continue
            }
            if character == "#" {
                spans.append(Span(range: index..<line.endIndex, role: .comment))
                break
            }
            let start = index
            if let end = endOfOperator(in: line, from: index) {
                index = end
                let word = String(line[start..<index])
                let redirect = word.contains(">") || word.contains("<")
                spans.append(Span(range: start..<index, role: redirect ? .redirect : .separator))
                // `2>&1` names a descriptor; only `> file` is followed by a path.
                let duplicatesDescriptor = word.contains(">&") || word.contains("<&")
                if redirect { afterRedirection = !duplicatesDescriptor }
                else if commandResets.contains(word) || word == ")" || word == "}" { expectingCommand = true; declaring = false }
                continue
            }
            if character == "\"" || character == "'" {
                index = endOfQuote(in: line, from: index, quote: character)
                appendString(start..<index, in: line, to: &spans)
                if afterRedirection { afterRedirection = false }
                else { expectingCommand = false }
                continue
            }
            index = endOfWord(in: line, from: index)
            let word = String(line[start..<index])
            let role: Role
            if afterRedirection {
                role = .path
                afterRedirection = false
            } else if isAssignment(word), expectingCommand || declaring {
                role = .assignment
            } else if reserved.contains(word) {
                role = .reserved
                expectingCommand = ["then", "else", "elif", "do", "in", "("].contains(word)
            } else if precommands.contains(word), expectingCommand {
                role = builtins.contains(word) ? .builtin : .reserved
            } else if word.hasPrefix("$") {
                role = word.hasPrefix("$(") || word.hasPrefix("$((") ? .expansion : .variable
                expectingCommand = false
            } else if expectingCommand {
                role = builtins.contains(word) ? .builtin : .command
                declaring = declarers.contains(word)
                expectingCommand = false
            } else if word.hasPrefix("-") {
                role = .flag
                // `--config=/etc/app`: the flag, then its value as what it is.
                if word.hasPrefix("--"), let equals = word.firstIndex(of: "="), word.index(after: equals) < word.endIndex {
                    let split = line.index(start, offsetBy: word.distance(from: word.startIndex, to: equals) + 1)
                    spans.append(Span(range: start..<split, role: .flag))
                    let value = String(line[split..<index])
                    if value.hasPrefix("\"") || value.hasPrefix("'") {
                        appendString(split..<index, in: line, to: &spans)
                    } else {
                        let valueRole: Role = value.hasPrefix("$") ? .variable : looksLikePath(value) ? .path : .argument
                        spans.append(Span(range: split..<index, role: valueRole))
                    }
                    continue
                }
            } else if looksLikePath(word) {
                role = .path
            } else if word.contains("*") || word.contains("?") || word.contains("[") {
                role = .glob
            } else {
                role = .argument
            }
            spans.append(Span(range: start..<index, role: role))
        }
        return spans
    }

    /// A quoted string as spans. Inside double quotes, `$NAME`, `${NAME}` and
    /// `$1`-style expansions are their own spans, in the variable colour,
    /// between the string's pieces; single quotes expand nothing. The spans
    /// never overlap, so every consumer can lay them end to end.
    private static func appendString(_ range: Range<String.Index>, in line: String, to spans: inout [Span]) {
        guard line[range].hasPrefix("\"") else {
            spans.append(Span(range: range, role: .string))
            return
        }
        var piece = range.lowerBound
        var index = range.lowerBound
        func flush(to end: String.Index) {
            if piece < end { spans.append(Span(range: piece..<end, role: .string)) }
        }
        while index < range.upperBound {
            let character = line[index]
            if character == "\\", line.index(after: index) < range.upperBound {
                index = line.index(index, offsetBy: 2)
                continue
            }
            if character == "$", let end = endOfExpansion(in: line, from: index, limit: range.upperBound) {
                flush(to: index)
                spans.append(Span(range: index..<end, role: .variable))
                piece = end
                index = end
                continue
            }
            index = line.index(after: index)
        }
        flush(to: range.upperBound)
    }

    /// `$NAME`, `${...}`, or a one-character special (`$1`, `$?`, `$$`); not `$(`.
    private static func endOfExpansion(in line: String, from dollar: String.Index, limit: String.Index) -> String.Index? {
        let next = line.index(after: dollar)
        guard next < limit else { return nil }
        let character = line[next]
        if character == "{" {
            guard let close = line[next..<limit].firstIndex(of: "}") else { return nil }
            return line.index(after: close)
        }
        if character.isLetter || character == "_" {
            var end = next
            while end < limit, line[end].isLetter || line[end].isNumber || line[end] == "_" { end = line.index(after: end) }
            return end
        }
        if character.isNumber || "?$!#@*-".contains(character) { return line.index(after: next) }
        return nil
    }

    private static func isAssignment(_ word: String) -> Bool {
        guard let equals = word.firstIndex(of: "="), equals != word.startIndex else { return false }
        let name = word[..<equals]
        guard name.first?.isLetter == true || name.first == "_" else { return false }
        return name.allSatisfy { $0.isLetter || $0.isNumber || $0 == "_" }
    }

    /// Operators are tokens even without surrounding spaces (`a&&b`, `2>f`).
    /// Braces only count on their own (`{ cmd; }`): inside a word they are
    /// an expansion (`${HOME}`, `{a,b}`). A redirection to a descriptor
    /// (`2>&1`, `>&2`) is one token.
    private static func endOfOperator(in line: String, from start: String.Index) -> String.Index? {
        let tail = line[start...]
        let operators = ["2>>", "2>", "&>>", "&>", ">>", "<<", "||", "&&", "|&", ">", "<", "|", ";", "&", "(", ")", "{", "}"]
        guard let op = operators.first(where: { tail.hasPrefix($0) }) else { return nil }
        var end = line.index(start, offsetBy: op.count)
        if op == "{" || op == "}" {
            let before = start == line.startIndex ? nil : line[line.index(before: start)]
            let after = end == line.endIndex ? nil : line[end]
            guard before.map({ $0 == " " || $0 == "\t" }) ?? true, after.map({ $0 == " " || $0 == "\t" }) ?? true else { return nil }
        }
        if op.contains(">") || op.contains("<"), !op.contains("&"), end < line.endIndex, line[end] == "&" {
            var next = line.index(after: end)
            let afterAmpersand = next
            while next < line.endIndex, line[next].isNumber { next = line.index(after: next) }
            if next < line.endIndex, line[next] == "-" { next = line.index(after: next) }
            if next > afterAmpersand { end = next }
        }
        return end
    }

    /// True for words that read as a filesystem path rather than a plain word.
    static func looksLikePath(_ word: String) -> Bool {
        word.hasPrefix("/") || word.hasPrefix("./") || word.hasPrefix("../")
            || word.hasPrefix("~") || (word.contains("/") && !word.contains("://"))
    }

    private static func endOfQuote(in line: String, from start: String.Index, quote: Character) -> String.Index {
        var index = line.index(after: start)
        while index < line.endIndex {
            if line[index] == "\\", line.index(after: index) < line.endIndex {
                index = line.index(index, offsetBy: 2)
                continue
            }
            if line[index] == quote { return line.index(after: index) }
            index = line.index(after: index)
        }
        return line.endIndex
    }

    private static func endOfWord(in line: String, from start: String.Index) -> String.Index {
        var index = start
        while index < line.endIndex {
            let character = line[index]
            if character == " " || character == "\t" || character == "#"
                || endOfOperator(in: line, from: index) != nil { break }
            if character == "\\", line.index(after: index) < line.endIndex {
                index = line.index(index, offsetBy: 2)
                continue
            }
            if character == "\"" || character == "'" {
                index = endOfQuote(in: line, from: index, quote: character)
                continue
            }
            index = line.index(after: index)
        }
        return index
    }
}
