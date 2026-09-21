import Foundation

/// A language-agnostic highlighter for code in the transcript: comments,
/// strings, numbers, keywords, and capitalized names as types. Not a
/// parser, just enough color to read diffs and snippets at a glance.
enum CodeHighlighter {
    enum Kind: Equatable { case plain, keyword, type, string, comment, number }

    struct Span: Equatable {
        let text: String
        let kind: Kind
    }

    /// Carried from line to line so block comments span lines.
    struct State: Equatable { var inBlockComment = false }

    static let keywords: Set<String> = [
        // Shared across C-family, Swift, TypeScript, Rust, Go, Python, Ruby, shell.
        "func", "function", "def", "fn", "let", "var", "const", "val", "static", "readonly", "public", "private",
        "protected", "internal", "fileprivate", "open", "final", "class", "struct", "enum", "interface", "type",
        "protocol", "extension", "impl", "trait", "import", "export", "from", "package", "module", "return", "if",
        "else", "elif", "guard", "switch", "case", "default", "for", "while", "repeat", "do", "in", "of", "break",
        "continue", "try", "catch", "throw", "throws", "finally", "async", "await", "new", "self", "Self", "this",
        "super", "nil", "null", "undefined", "true", "false", "None", "True", "False", "as", "is", "where", "mut",
        "pub", "use", "go", "defer", "select", "chan", "then", "fi", "esac", "done", "echo", "lambda", "yield",
        "with", "extends", "implements", "override", "init", "deinit", "some", "any", "inout", "typeof", "keyof",
    ]

    static func highlight(_ line: String, state: inout State) -> [Span] {
        var spans: [Span] = []
        let chars = Array(line)
        var index = 0
        var plain = ""

        func flush() {
            if !plain.isEmpty { spans.append(Span(text: plain, kind: .plain)) }
            plain = ""
        }
        func take(_ count: Int, as kind: Kind) {
            flush()
            spans.append(Span(text: String(chars[index..<min(chars.count, index + count)]), kind: kind))
            index += count
        }
        func starts(with prefix: String) -> Bool {
            let p = Array(prefix)
            return index + p.count <= chars.count && Array(chars[index..<index + p.count]) == p
        }

        while index < chars.count {
            if state.inBlockComment {
                var end = index
                while end < chars.count, !(chars[end] == "*" && end + 1 < chars.count && chars[end + 1] == "/") { end += 1 }
                if end < chars.count { end += 2; state.inBlockComment = false }
                take(end - index, as: .comment)
                continue
            }
            let c = chars[index]
            if starts(with: "/*") {
                state.inBlockComment = true
                continue
            }
            if starts(with: "//") || (c == "#" && (index == 0 || chars[index - 1] == " ") && !starts(with: "#{")) {
                take(chars.count - index, as: .comment)
                continue
            }
            if c == "\"" || c == "'" || c == "`" {
                var end = index + 1
                while end < chars.count, chars[end] != c {
                    end += chars[end] == "\\" ? 2 : 1
                }
                take(min(chars.count, end + 1) - index, as: .string)
                continue
            }
            if c.isNumber, index == 0 || !(chars[index - 1].isLetter || chars[index - 1] == "_") {
                var end = index
                while end < chars.count, chars[end].isNumber || chars[end] == "." || chars[end] == "_" || chars[end].isHexDigit { end += 1 }
                take(end - index, as: .number)
                continue
            }
            if c.isLetter || c == "_" {
                var end = index
                while end < chars.count, chars[end].isLetter || chars[end].isNumber || chars[end] == "_" { end += 1 }
                let word = String(chars[index..<end])
                if keywords.contains(word) {
                    take(end - index, as: .keyword)
                } else if word.first?.isUppercase == true {
                    take(end - index, as: .type)
                } else {
                    plain += word
                    index = end
                }
                continue
            }
            plain.append(c)
            index += 1
        }
        flush()
        return spans
    }
}
