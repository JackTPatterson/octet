import Foundation

/// What can be completed at the caret: the command itself, a path, a flag, or
/// something only that command knows about (a git branch). Kept pure so the
/// rules can be tested without a shell.
struct Completion: Identifiable, Equatable {
    enum Kind: Equatable {
        case command
        case builtin
        case file
        case directory
        case flag
        case history
        case branch
        case repository

        var symbol: String {
            switch self {
            case .command: "terminal"
            case .builtin: "gearshape"
            case .file: "doc"
            case .directory: "folder"
            case .flag: "minus"
            case .history: "clock"
            case .branch: "arrow.triangle.branch"
            case .repository: "square.and.arrow.down.on.square"
            }
        }
    }

    let value: String
    let kind: Kind
    var detail: String = ""
    /// What the menu shows and matches when the inserted value is unwieldy,
    /// like a repository's name for its clone URL.
    var label: String?
    var id: String { "\(kind):\(value)" }
    var shown: String { label ?? value }
}

/// The word being completed and where it sits in the line.
struct CompletionContext: Equatable {
    /// Text of the word under the caret.
    let token: String
    /// Range of that word in the line, as character offsets.
    let range: Range<Int>
    /// The command the line starts with, when the caret is past it.
    let command: String?
    /// The word before the one being typed, which decides what fits here.
    var previousWord: String?
    /// True when the caret is on the first word.
    var isCommandPosition: Bool { command == nil }
    /// Words between the command and the caret's own word, which say which
    /// subcommand a spec is in.
    var wordsBeforeToken: [String] = []

    /// Splits a line at the caret into the word being typed and its command.
    static func at(caret: Int, in line: String) -> CompletionContext {
        let characters = Array(line)
        var start = min(caret, characters.count)
        while start > 0, !characters[start - 1].isWhitespace { start -= 1 }
        var end = min(caret, characters.count)
        while end < characters.count, !characters[end].isWhitespace { end += 1 }
        let token = String(characters[start..<end])

        // The command is the first word, unless the caret is on it.
        var firstEnd = 0
        while firstEnd < characters.count, characters[firstEnd].isWhitespace { firstEnd += 1 }
        let firstStart = firstEnd
        while firstEnd < characters.count, !characters[firstEnd].isWhitespace { firstEnd += 1 }
        let first = String(characters[firstStart..<firstEnd])
        let onFirstWord = start <= firstStart
        // The word before the caret's own, for commands that take a branch.
        var previousEnd = start
        while previousEnd > 0, characters[previousEnd - 1].isWhitespace { previousEnd -= 1 }
        var previousStart = previousEnd
        while previousStart > 0, !characters[previousStart - 1].isWhitespace { previousStart -= 1 }
        let previous = previousStart < previousEnd ? String(characters[previousStart..<previousEnd]) : nil
        let before = String(characters[0..<start])
            .split(separator: " ")
            .map(String.init)
        return CompletionContext(
            token: token,
            range: start..<end,
            command: onFirstWord || first.isEmpty ? nil : first,
            previousWord: previous,
            wordsBeforeToken: Array(before.dropFirst())
        )
    }
}

enum Completions {
    /// Subcommands worth offering for commands people use constantly.
    static let subcommands: [String: [String]] = [
        "git": ["add", "branch", "checkout", "cherry-pick", "clone", "commit", "diff", "fetch", "log",
                "merge", "pull", "push", "rebase", "remote", "reset", "restore", "revert", "show",
                "stash", "status", "switch", "tag", "worktree"],
        "cargo": ["add", "bench", "build", "check", "clean", "clippy", "doc", "fmt", "init", "new",
                  "publish", "run", "test", "update"],
        "npm": ["ci", "init", "install", "link", "publish", "run", "start", "test", "uninstall", "update"],
        "docker": ["build", "compose", "exec", "images", "logs", "ps", "pull", "push", "run", "stop"],
        "brew": ["cleanup", "doctor", "info", "install", "list", "outdated", "search", "uninstall", "update", "upgrade"],
    ]

    /// Commands whose next word is a git branch.
    static let branchTaking: Set<String> = ["checkout", "switch", "merge", "rebase"]

    /// Ranks candidates for the word at the caret. `commands` are the names
    /// on PATH, `entries` the files in the token's directory, `history` past
    /// command lines, `branches` this repo's branches.
    static func suggestions(
        for context: CompletionContext,
        commands: [String] = [],
        entries: [(name: String, isDirectory: Bool)] = [],
        history: [String] = [],
        branches: [String] = [],
        spec: CompletionSpec? = nil,
        generatorValues: [String] = [],
        project: [ProjectCommands.Entry] = [],
        predictions: [String] = [],
        limit: Int = 12
    ) -> [Completion] {
        var candidates: [Completion] = []
        let token = context.token

        // A spec for this command knows more than any heuristic can.
        if let command = context.command, let spec = spec {
            candidates += fromSpec(spec, words: context.wordsBeforeToken, token: token,
                                   entries: entries, generatorValues: generatorValues)
            _ = command
        }

        if context.isCommandPosition {
            candidates += ShellSyntax.builtins.map { Completion(value: $0, kind: .builtin) }
            candidates += commands.map { Completion(value: $0, kind: .command) }
            // A whole line from history is worth more than a bare name.
            candidates += history.prefix(200).map { Completion(value: $0, kind: .history) }
            // What this folder can run, and what usually comes next.
            candidates += project.map { Completion(value: $0.command, kind: .command, detail: $0.source) }
            candidates += predictions.map { Completion(value: $0, kind: .history, detail: "next") }
        } else {
            if let command = context.command {
                // A historical `cd foo` is only valid in the directory where
                // it was run. Current filesystem entries are the source of
                // truth for cd; never mix stale history paths into its menu.
                let second = command == "cd" ? [] : secondWord(of: history, command: command)
                // Subcommands belong right after the command, not deeper in.
                if let subs = subcommands[command], context.previousWord == command {
                    candidates += subs.map { Completion(value: $0, kind: .command, detail: command) }
                }
                // `git switch <branch>`: the word before decides.
                if command == "git", let previous = context.previousWord, branchTaking.contains(previous) {
                    candidates += branches.map { Completion(value: $0, kind: .branch) }
                }
                candidates += second.map { Completion(value: $0, kind: .history, detail: command) }
            }
            if token.hasPrefix("-") {
                candidates += flags(in: history, command: context.command).map { Completion(value: $0, kind: .flag) }
            }
            let relevantEntries = context.command == "cd"
                ? entries.filter { $0.isDirectory }
                : entries
            candidates += relevantEntries.map { entry in
                Completion(value: entry.isDirectory ? entry.name + "/" : entry.name,
                           kind: entry.isDirectory ? .directory : .file)
            }
        }

        return rank(candidates, matching: token, limit: limit)
    }

    /// Candidates a spec offers at the caret: subcommands and options with
    /// their descriptions, plus the argument's values. Generator values are
    /// passed in, since running a command is the caller's business.
    static func fromSpec(
        _ spec: CompletionSpec,
        words: [String],
        token: String,
        entries: [(name: String, isDirectory: Bool)] = [],
        generatorValues: [String] = []
    ) -> [Completion] {
        let offered = spec.candidates(after: words)
        var candidates: [Completion] = offered.names.map { entry in
            Completion(
                value: entry.value,
                kind: entry.value.hasPrefix("-") ? .flag : .command,
                detail: entry.summary
            )
        }
        switch offered.argument {
        case .file, .directory:
            candidates += entries.map {
                Completion(value: $0.isDirectory ? $0.name + "/" : $0.name, kind: $0.isDirectory ? .directory : .file)
            }
        case .generator(let generator):
            candidates += generatorValues.map { line in
                // `value<TAB>label<TAB>detail`; a plain line is its own value.
                let fields = line.components(separatedBy: "\t")
                let label = fields.count > 1 && !fields[1].isEmpty ? fields[1] : nil
                return Completion(value: fields[0], kind: generator.kind,
                                  detail: fields.count > 2 ? fields[2] : "", label: label)
            }
        case .values(let values):
            candidates += values.map { Completion(value: $0, kind: .command) }
        case nil:
            break
        }
        return candidates
    }

    /// The generator an argument uses at the caret, if any.
    static func generator(for spec: CompletionSpec, words: [String]) -> CompletionSpec.Generator? {
        if case .generator(let generator) = spec.candidates(after: words).argument { return generator }
        return nil
    }

    /// Prefix matches first, then fuzzy, shortest first, no duplicates.
    static func rank(_ candidates: [Completion], matching token: String, limit: Int) -> [Completion] {
        var seen = Set<String>()
        var scored: [(Completion, Int)] = []
        let needle = token.lowercased()
        for candidate in candidates {
            guard seen.insert(candidate.id).inserted, candidate.value != token else { continue }
            if needle.isEmpty {
                scored.append((candidate, 0))
                continue
            }
            let value = candidate.shown.lowercased()
            if value.hasPrefix(needle) || candidate.value.lowercased().hasPrefix(needle) {
                scored.append((candidate, 1_000 - candidate.shown.count))
            } else if let match = FuzzyMatcher.match(needle, in: candidate.shown) {
                scored.append((candidate, match.score))
            }
        }
        // Repositories arrive most recently pushed first; among equals that
        // order is the useful one, where sorting by length would scramble it.
        let position = Dictionary(scored.enumerated().map { ($0.element.0.id, $0.offset) }) { first, _ in first }
        scored.sort { first, second in
            guard first.1 == second.1 else { return first.1 > second.1 }
            if first.0.kind == .repository, second.0.kind == .repository {
                return position[first.0.id, default: 0] < position[second.0.id, default: 0]
            }
            return first.0.shown.count < second.0.shown.count
        }
        return scored.prefix(limit).map(\.0)
    }

    /// Flags this command has been given before, harvested from history.
    static func flags(in history: [String], command: String?) -> [String] {
        var flags: Set<String> = []
        for line in history {
            let words = line.split(separator: " ").map(String.init)
            guard let first = words.first, command == nil || first == command else { continue }
            for word in words.dropFirst() where word.hasPrefix("-") && word.count > 1 {
                flags.insert(word)
            }
        }
        return flags.sorted()
    }

    /// Words that have followed this command before.
    static func secondWord(of history: [String], command: String) -> [String] {
        var words: [String] = []
        var seen = Set<String>()
        for line in history {
            let parts = line.split(separator: " ").map(String.init)
            guard parts.first == command, parts.count > 1 else { continue }
            let word = parts[1]
            guard !word.hasPrefix("-"), seen.insert(word).inserted else { continue }
            words.append(word)
        }
        return words
    }

    // MARK: - Reading the machine

    /// Executable names on PATH, read once and cached by the caller.
    static func commandsOnPath(environment: [String: String] = ProcessInfo.processInfo.environment) -> [String] {
        let manager = FileManager.default
        var names = Set<String>()
        for directory in (environment["PATH"] ?? "").split(separator: ":").map(String.init) {
            for name in (try? manager.contentsOfDirectory(atPath: directory)) ?? [] {
                guard manager.isExecutableFile(atPath: directory + "/" + name) else { continue }
                names.insert(name)
            }
        }
        return names.sorted()
    }

    /// Files beside the token being typed, for path completion.
    static func entries(for token: String, cwd: String) -> [(name: String, isDirectory: Bool)] {
        if token == "." { return [(".", true), ("..", true)] }
        if token == ".." { return [("..", true)] }
        let expanded = (token as NSString).expandingTildeInPath
        let directoryPart = expanded.contains("/") ? (expanded as NSString).deletingLastPathComponent : ""
        let base: String
        if directoryPart.hasPrefix("/") {
            base = directoryPart
        } else if directoryPart.isEmpty {
            base = cwd
        } else {
            base = cwd + "/" + directoryPart
        }
        let manager = FileManager.default
        let names = (try? manager.contentsOfDirectory(atPath: base)) ?? []
        // Keep a typed tilde in what is inserted even though filesystem
        // lookup uses its expanded path.
        let typedDirectory = token.contains("/") ? (token as NSString).deletingLastPathComponent : ""
        let prefix = typedDirectory.isEmpty ? "" : typedDirectory + "/"
        return names.filter { !$0.hasPrefix(".") }.sorted().map { name in
            var isDirectory: ObjCBool = false
            manager.fileExists(atPath: base + "/" + name, isDirectory: &isDirectory)
            return (prefix + name, isDirectory.boolValue)
        }
    }

    /// Local branches, for the git commands that take one.
    static func branches(in cwd: String) -> [String] {
        guard let head = GitBranch.repositoryRoot(for: cwd) else { return [] }
        let refs = head + "/.git/refs/heads"
        var names: [String] = []
        let manager = FileManager.default
        if let enumerator = manager.enumerator(atPath: refs) {
            for case let name as String in enumerator where !name.hasPrefix(".") {
                var isDirectory: ObjCBool = false
                manager.fileExists(atPath: refs + "/" + name, isDirectory: &isDirectory)
                if !isDirectory.boolValue { names.append(name) }
            }
        }
        return names.sorted()
    }
}
