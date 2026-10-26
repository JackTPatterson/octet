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

    /// The quote the word at the caret is inside, if it is still open.
    var openQuote: Character?
    /// Whether the word was typed starting with a quote (which `range` includes).
    var startsWithQuote = false

    /// One word of the line as typed: where it sits, what it says once its
    /// quotes and backslashes are taken off, and the quote it left open.
    private struct Word {
        var start: Int
        var end: Int
        var value: String
        var openQuote: Character?
        var startsWithQuote: Bool
        var segment: Int
    }

    /// Reads the line like a shell would, as far as completion needs: words
    /// split by unquoted, unescaped spaces; `'...'`, `"..."` and `\ ` kept
    /// inside one word; and a pipe, `&&`, `||`, `;`, `&` or `(` starting a
    /// new command (not `2>&1` or `&>`).
    private static func words(of characters: [Character]) -> (words: [Word], breaks: [Int]) {
        var words: [Word] = []
        var breaks: [Int] = []          // character offsets where a new command begins
        var current: Word?
        var quote: Character?
        var index = 0
        func finish(at end: Int) {
            guard var word = current else { return }
            word.end = end
            word.openQuote = quote
            words.append(word)
            current = nil
            quote = nil
        }
        func begin(at start: Int, quoted: Bool) {
            current = Word(start: start, end: start, value: "", openQuote: nil, startsWithQuote: quoted, segment: breaks.count)
        }
        while index < characters.count {
            let character = characters[index]
            if let open = quote {
                if character == open { quote = nil }
                else if character == "\\", open == "\"", index + 1 < characters.count,
                        "\"$`\\".contains(characters[index + 1]) {
                    index += 1
                    current?.value.append(characters[index])
                } else { current?.value.append(character) }
                index += 1
                continue
            }
            if character == " " || character == "\t" {
                finish(at: index)
            } else if character == "\\", index + 1 < characters.count {
                if current == nil { begin(at: index, quoted: false) }
                index += 1
                current?.value.append(characters[index])
            } else if character == "\"" || character == "'" {
                if current == nil { begin(at: index, quoted: true) }
                quote = character
            } else if "|;&(".contains(character) || character == ")" || character == ">" || character == "<" {
                finish(at: index)
                if "|;&(".contains(character) {
                    let redirected = character == "&" && index > 0 && (characters[index - 1] == ">" || characters[index - 1] == "<")
                    let redirecting = character == "&" && index + 1 < characters.count && characters[index + 1] == ">"
                    if !redirected && !redirecting { breaks.append(index + 1) }
                }
            } else {
                if current == nil { begin(at: index, quoted: false) }
                current?.value.append(character)
            }
            index += 1
        }
        finish(at: characters.count)
        return (words, breaks)
    }

    /// Splits a line at the caret into the word being typed and its command.
    /// `token` is the word as it will be read (quotes and backslashes off);
    /// `range` is where it sits in the line, to replace as typed.
    static func at(caret: Int, in line: String) -> CompletionContext {
        let characters = Array(line)
        let caret = min(max(caret, 0), characters.count)
        let (all, breaks) = words(of: characters)
        let caretSegment = breaks.filter { $0 <= caret }.count
        let here = all.first { $0.start <= caret && caret <= $0.end && $0.segment == caretSegment }
        let before = all.filter { $0.segment == caretSegment && $0.end <= (here?.start ?? caret) && $0.start < (here?.start ?? caret) }
        let first = before.first
        return CompletionContext(
            token: here?.value ?? "",
            range: (here?.start ?? caret)..<(here?.end ?? caret),
            command: first?.value,
            previousWord: before.last?.value,
            wordsBeforeToken: before.dropFirst().map(\.value),
            openQuote: here?.openQuote,
            startsWithQuote: here?.startsWithQuote ?? false
        )
    }

    /// What goes in the line for `completion`: a path is written the way the
    /// word being typed is quoted (or backslash-escaped, if it isn't), so a
    /// name with a space completes to something the shell reads back whole.
    func insertion(for completion: Completion) -> String {
        guard completion.kind == .file || completion.kind == .directory else { return completion.value }
        let value = completion.value
        let quote = openQuote
        var text = ""
        if let quote {
            text = String(quote)
            for character in value {
                if quote == "\"", "\"$`\\".contains(character) { text.append("\\") }
                text.append(character)
            }
            // A file ends its word; a folder stays open for what follows.
            if completion.kind == .file { text.append(quote) }
        } else {
            let special: Set<Character> = [" ", "\t", "(", ")", "&", ";", "|", "<", ">", "*", "?", "[", "]", "{", "}",
                                           "$", "`", "\"", "'", "\\", "!", "#", "^"]
            for (offset, character) in value.enumerated() {
                // A leading `~` is the home folder, not a name.
                if special.contains(character) && !(offset == 0 && character == "~") { text.append("\\") }
                text.append(character)
            }
        }
        return text
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
        "pnpm": ["add", "build", "dev", "dlx", "exec", "install", "remove", "run", "start", "test", "update"],
        "yarn": ["add", "build", "dev", "install", "remove", "run", "start", "test", "upgrade"],
        "bun": ["add", "build", "dev", "install", "remove", "run", "test", "update", "x"],
        "gh": ["api", "auth", "browse", "codespace", "gist", "issue", "pr", "release", "repo", "run", "workflow"],
        "supabase": ["db", "functions", "gen", "init", "link", "login", "migration", "projects", "secrets", "start", "status", "stop"],
        "kubectl": ["apply", "config", "delete", "describe", "exec", "get", "logs", "port-forward", "rollout", "scale"],
        "terraform": ["apply", "destroy", "fmt", "import", "init", "output", "plan", "state", "validate", "workspace"],
    ]

    /// Whether the word at the caret is already a whole word that fits
    /// there: a command, a subcommand, or an option. Tab then finishes it
    /// with a space, as a shell would, rather than having nothing to offer.
    static func isCompleteWord(_ context: CompletionContext, spec: CompletionSpec?, commands: [String] = []) -> Bool {
        let token = context.token
        guard !token.isEmpty else { return false }
        if context.isCommandPosition {
            return ShellSyntax.builtins.contains(token) || commands.contains(token)
        }
        if let spec, spec.candidates(after: context.wordsBeforeToken).names.contains(where: { $0.value == token }) {
            return true
        }
        if let command = context.command, context.previousWord == command {
            return subcommands[command]?.contains(token) == true
        }
        return false
    }

    /// Commands whose next word is a git branch.
    static let branchTaking: Set<String> = [
        "checkout", "switch", "merge", "rebase", "branch", "diff", "log", "cherry-pick", "reset", "show", "revert",
        "-d", "-D", "-m", "-M", "--delete",
    ]

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
        historyIsRanked: Bool = false,
        limit: Int = 12
    ) -> [Completion] {
        var candidates: [Completion] = []
        let token = context.token
        // When a spec says where this argument's values come from, those are
        // the answer; files and history words would only crowd them out.
        let specArgument = context.isCommandPosition ? nil : spec?.candidates(after: context.wordsBeforeToken).argument
        let specOwnsArgument: Bool = {
            switch specArgument {
            case .generator, .values: return true
            default: return false
            }
        }()

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
                // Words that followed this command before belong right after it,
                // not in a later argument's place.
                let second = command == "cd" || specOwnsArgument || context.previousWord != command
                    ? [] : secondWord(of: history, command: command)
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
            // A spec that names the argument's kind has already offered its
            // paths (only folders where it wants one).
            let relevantEntries = specArgument != nil ? []
                : context.command == "cd" ? entries.filter { $0.isDirectory }
                : entries
            candidates += relevantEntries.map { entry in
                Completion(value: entry.isDirectory ? entry.name + "/" : entry.name,
                           kind: entry.isDirectory ? .directory : .file)
            }
        }

        return rank(candidates, matching: token, limit: limit, historyIsRanked: historyIsRanked)
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
        // Flags wait for a dash, so a word's real values lead the menu.
        let names = token.hasPrefix("-") ? offered.names : offered.names.filter { !$0.value.hasPrefix("-") }
        var candidates: [Completion] = names.map { entry in
            Completion(
                value: entry.value,
                kind: entry.value.hasPrefix("-") ? .flag : .command,
                detail: entry.summary
            )
        }
        switch offered.argument {
        case .directory:
            candidates += entries.filter(\.isDirectory).map { Completion(value: $0.name + "/", kind: .directory) }
        case .file:
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
    /// With `historyIsRanked`, history lines arrive best first (by how often
    /// and how lately you ran them, and where) and keep that order, ahead of
    /// bare command names that match the same letters.
    static func rank(_ candidates: [Completion], matching token: String, limit: Int,
                     historyIsRanked: Bool = false) -> [Completion] {
        var seen = Set<String>()
        var scored: [(Completion, Int)] = []
        let needle = token.lowercased()
        var historyPlace = 0
        for candidate in candidates {
            guard seen.insert(candidate.id).inserted, candidate.value != token else { continue }
            if historyIsRanked, candidate.kind == .history {
                // Whatever it matches, its place in your habits decides.
                let matches = needle.isEmpty || candidate.value.lowercased().hasPrefix(needle)
                    || FuzzyMatcher.match(needle, in: candidate.shown) != nil
                if matches {
                    scored.append((candidate, 1_200 - min(historyPlace, 150)))
                    historyPlace += 1
                }
                continue
            }
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
            let firstIsRepository = first.0.kind == .repository
            let secondIsRepository = second.0.kind == .repository
            if firstIsRepository != secondIsRepository { return firstIsRepository }
            if firstIsRepository {
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
        let names = listing(of: base)
        // Keep a typed tilde in what is inserted even though filesystem
        // lookup uses its expanded path.
        let typedDirectory = token.contains("/") ? (token as NSString).deletingLastPathComponent : ""
        let prefix = typedDirectory.isEmpty ? "" : typedDirectory + "/"
        // Dotfiles stay out of the way until the word being typed starts with one.
        let typedName = token.split(separator: "/", omittingEmptySubsequences: false).last.map(String.init) ?? ""
        let showsHidden = typedName.hasPrefix(".")
        return names.filter { showsHidden || !$0.hasPrefix(".") }.sorted().map { name in
            var isDirectory: ObjCBool = false
            manager.fileExists(atPath: base + "/" + name, isDirectory: &isDirectory)
            return (prefix + name, isDirectory.boolValue)
        }
    }

    /// A folder's names, kept a few seconds: a menu that reopens on every
    /// keystroke shouldn't read a big folder (Downloads, node_modules) each time.
    private static let listingLock = NSLock()
    nonisolated(unsafe) private static var listings: [String: (names: [String], at: Date)] = [:]

    private static func listing(of directory: String) -> [String] {
        if let hit = listingLock.withLock({ listings[directory] }), Date().timeIntervalSince(hit.at) < 3 { return hit.names }
        let names = (try? FileManager.default.contentsOfDirectory(atPath: directory)) ?? []
        listingLock.withLock {
            if listings.count > 40 { listings = [:] }
            listings[directory] = (names, Date())
        }
        return names
    }

    /// Local branches, then remote ones not already local, for the git
    /// commands that take one. Reads the repository's files, so it works in
    /// a linked worktree (whose `.git` is a file) and for branches git has
    /// packed into `packed-refs`.
    static func branches(in cwd: String) -> [String] {
        guard let root = GitBranch.repositoryRoot(for: cwd) else { return [] }
        let manager = FileManager.default
        var gitDirectory = root + "/.git"
        var isDirectory: ObjCBool = false
        if manager.fileExists(atPath: gitDirectory, isDirectory: &isDirectory), !isDirectory.boolValue,
           let pointer = try? String(contentsOfFile: gitDirectory, encoding: .utf8),
           let line = pointer.split(separator: "\n").first(where: { $0.hasPrefix("gitdir:") }) {
            let path = line.dropFirst("gitdir:".count).trimmingCharacters(in: .whitespaces)
            gitDirectory = path.hasPrefix("/") ? path : root + "/" + path
        }
        // A worktree's refs live in the main repository's folder.
        var common = gitDirectory
        if let pointer = try? String(contentsOfFile: gitDirectory + "/commondir", encoding: .utf8) {
            let path = pointer.trimmingCharacters(in: .whitespacesAndNewlines)
            common = path.hasPrefix("/") ? path : (gitDirectory + "/" + path)
            common = (common as NSString).standardizingPath
        }
        func loose(_ folder: String) -> [String] {
            var names: [String] = []
            if let enumerator = manager.enumerator(atPath: common + "/" + folder) {
                for case let name as String in enumerator where !name.hasPrefix(".") && !name.hasSuffix(".lock") {
                    var isDirectory: ObjCBool = false
                    manager.fileExists(atPath: common + "/" + folder + "/" + name, isDirectory: &isDirectory)
                    if !isDirectory.boolValue { names.append(name) }
                }
            }
            return names
        }
        var local = Set(loose("refs/heads"))
        var remote = Set(loose("refs/remotes").filter { !$0.hasSuffix("/HEAD") })
        if let packed = try? String(contentsOfFile: common + "/packed-refs", encoding: .utf8) {
            for line in packed.split(separator: "\n") where !line.hasPrefix("#") && !line.hasPrefix("^") {
                let fields = line.split(separator: " ", maxSplits: 1)
                guard fields.count == 2 else { continue }
                let ref = String(fields[1])
                if ref.hasPrefix("refs/heads/") { local.insert(String(ref.dropFirst("refs/heads/".count))) }
                else if ref.hasPrefix("refs/remotes/"), !ref.hasSuffix("/HEAD") { remote.insert(String(ref.dropFirst("refs/remotes/".count))) }
            }
        }
        // `git checkout feature` finds origin/feature: offer the short name too.
        let remoteOnly = remote.map { name -> String in
            name.split(separator: "/", maxSplits: 1).count == 2 ? String(name.split(separator: "/", maxSplits: 1)[1]) : name
        }.filter { !local.contains($0) }
        return local.sorted() + Set(remoteOnly).sorted()
    }
}
