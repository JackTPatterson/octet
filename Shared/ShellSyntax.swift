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

    static func spans(in line: String) -> [Span] {
        var spans: [Span] = []
        var index = line.startIndex
        var expectingCommand = true

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
            if character == "\"" || character == "'" {
                index = endOfQuote(in: line, from: index, quote: character)
                spans.append(Span(range: start..<index, role: .string))
                expectingCommand = false
                continue
            }
            index = endOfWord(in: line, from: index)
            let word = String(line[start..<index])
            let role: Role
            if commandResets.contains(word) {
                role = .separator
                expectingCommand = true
            } else if word.hasPrefix("<") || word.hasPrefix(">") || word.hasPrefix("2>") {
                role = .redirect
            } else if word.hasPrefix("$") {
                role = .variable
                expectingCommand = false
            } else if expectingCommand {
                role = builtins.contains(word) ? .builtin : .command
                expectingCommand = false
            } else if word.hasPrefix("-") {
                role = .flag
            } else if looksLikePath(word) {
                role = .path
            } else {
                role = .argument
            }
            spans.append(Span(range: start..<index, role: role))
        }
        return spans
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
            if character == " " || character == "\t" || character == "#" { break }
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
