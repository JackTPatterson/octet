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
    private static let precommands: Set<String> = ["sudo", "env", "command", "builtin", "noglob", "time", "xargs"]

    static func spans(in line: String) -> [Span] {
        var spans: [Span] = []
        var index = line.startIndex
        var expectingCommand = true
        var afterRedirection = false

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
                if redirect { afterRedirection = true }
                else if commandResets.contains(word) || word == ")" || word == "}" { expectingCommand = true }
                continue
            }
            if character == "\"" || character == "'" {
                index = endOfQuote(in: line, from: index, quote: character)
                spans.append(Span(range: start..<index, role: .string))
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
            } else if isAssignment(word), expectingCommand {
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
                expectingCommand = false
            } else if word.hasPrefix("-") {
                role = .flag
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

    private static func isAssignment(_ word: String) -> Bool {
        guard let equals = word.firstIndex(of: "="), equals != word.startIndex else { return false }
        let name = word[..<equals]
        guard name.first?.isLetter == true || name.first == "_" else { return false }
        return name.allSatisfy { $0.isLetter || $0.isNumber || $0 == "_" }
    }

    /// Operators are tokens even without surrounding spaces (`a&&b`, `2>f`).
    private static func endOfOperator(in line: String, from start: String.Index) -> String.Index? {
        let tail = line[start...]
        let operators = ["2>>", "2>", "&>>", "&>", ">>", "<<", "||", "&&", "|&", ">", "<", "|", ";", "&", "(", ")", "{", "}"]
        guard let op = operators.first(where: { tail.hasPrefix($0) }) else { return nil }
        return line.index(start, offsetBy: op.count)
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
