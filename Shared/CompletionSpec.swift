import Foundation

/// How a command completes, as data rather than code: subcommands, options, and arguments that name where their
/// values come from. Dynamic values (branches, npm scripts, containers) come
/// from a generator: one short command whose output is cached, so typing
/// never waits on a process.
struct CompletionSpec: Equatable {
    struct Option: Equatable {
        let names: [String]
        var summary: String = ""
        /// What follows the option, when it takes a value.
        var argument: Argument?
    }

    struct Subcommand: Equatable {
        let name: String
        var summary: String = ""
        var options: [Option] = []
        var argument: Argument?
        var subcommands: [Subcommand] = []
        /// `argument` fills only the first positional word; later ones are
        /// paths (`git clone <repo> <directory>`).
        var firstArgumentOnly = false
    }

    /// Where an argument's values come from.
    enum Argument: Equatable {
        case file
        case directory
        /// Values from a generator, named so results can be cached per folder.
        case generator(Generator)
        case values([String])
    }

    struct Generator: Equatable {
        let id: String
        /// Run in the pane's folder; one value per line, optionally
        /// `value<TAB>label<TAB>detail`.
        let command: String
        var cacheSeconds: TimeInterval = 10
        var kind: Completion.Kind = .branch
        /// False when the output doesn't depend on the folder, so one
        /// result serves every pane.
        var perFolder = true
        /// How long the command may run before it's abandoned.
        var timeout: TimeInterval = 2
    }

    let name: String
    var summary: String = ""
    var subcommands: [Subcommand] = []
    var options: [Option] = []
    var argument: Argument?

    /// Walks the words already typed to find which subcommand is in play.
    func resolve(words: [String]) -> Subcommand? { resolvePath(words).subcommand }

    /// The subcommand in play and how many words named it.
    private func resolvePath(_ words: [String]) -> (subcommand: Subcommand?, length: Int) {
        var current: Subcommand?
        var pool = subcommands
        var length = 0
        for word in words {
            guard let match = pool.first(where: { $0.name == word }) else { break }
            current = match
            pool = match.subcommands
            length += 1
        }
        return (current, length)
    }

    /// What can follow, given the words typed before the caret.
    func candidates(after words: [String]) -> (names: [(value: String, summary: String)], argument: Argument?) {
        let (resolved, length) = resolvePath(words)
        let subs = resolved?.subcommands ?? (resolved == nil ? subcommands : [])
        let options = (resolved?.options ?? []) + self.options
        let rest = words.dropFirst(length)
        // Right after an option that takes a value, only that value fits.
        if let last = rest.last, let option = options.first(where: { $0.names.contains(last) }),
           let value = option.argument {
            return ([], value)
        }
        var names = subs.map { (value: $0.name, summary: $0.summary) }
        names += options.flatMap { option in option.names.map { (value: $0, summary: option.summary) } }
        var argument = resolved?.argument ?? self.argument
        if resolved?.firstArgumentOnly == true, Self.positionals(in: rest, options: options) > 0 {
            argument = .directory
        }
        return (names, argument)
    }

    /// Words that are arguments rather than options or options' values.
    private static func positionals(in words: ArraySlice<String>, options: [Option]) -> Int {
        var count = 0
        var skipNext = false
        for word in words {
            if skipNext { skipNext = false; continue }
            if word.hasPrefix("-") {
                skipNext = options.first { $0.names.contains(word) }?.argument != nil
                continue
            }
            count += 1
        }
        return count
    }
}

enum CompletionSpecs {
    /// Octet ships a small set; the format is the point, so more are data.
    static let all: [String: CompletionSpec] = [
        "git": git,
        "npm": npm,
        "docker": docker,
        "cargo": cargo,
        "make": make,
    ]

    static func spec(for command: String) -> CompletionSpec? { all[command] }

    static let branches = CompletionSpec.Generator(
        id: "git.branches",
        command: "git for-each-ref --format='%(refname:short)' refs/heads refs/remotes --count=200",
        cacheSeconds: 5
    )

    static let git = CompletionSpec(
        name: "git",
        summary: "Version control",
        subcommands: [
            .init(name: "add", summary: "Stage changes", argument: .file),
            .init(name: "commit", summary: "Record staged changes", options: [
                .init(names: ["-m", "--message"], summary: "Commit message"),
                .init(names: ["--amend"], summary: "Replace the last commit"),
                .init(names: ["-a", "--all"], summary: "Stage tracked files first"),
            ]),
            .init(name: "checkout", summary: "Switch branches or restore files", argument: .generator(branches)),
            .init(name: "switch", summary: "Switch branches", argument: .generator(branches)),
            .init(name: "merge", summary: "Join histories", argument: .generator(branches)),
            .init(name: "rebase", summary: "Replay commits", argument: .generator(branches)),
            .init(name: "push", summary: "Send commits", options: [
                .init(names: ["--force-with-lease"], summary: "Overwrite if nothing new upstream"),
                .init(names: ["-u", "--set-upstream"], summary: "Track the remote branch"),
            ]),
            .init(name: "pull", summary: "Fetch and integrate"),
            .init(name: "clone", summary: "Copy a repository", options: [
                .init(names: ["--depth"], summary: "Only recent history", argument: .values([])),
                .init(names: ["-b", "--branch"], summary: "Check out this branch", argument: .values([])),
                .init(names: ["--recurse-submodules"], summary: "Clone submodules too"),
            // A URL to type (plugins can list repositories), then a folder.
            ], argument: .values([]), firstArgumentOnly: true),
            .init(name: "status", summary: "Show the working tree"),
            .init(name: "log", summary: "Show history", options: [
                .init(names: ["--oneline"], summary: "One line per commit"),
                .init(names: ["--graph"], summary: "Draw the history graph"),
            ]),
            .init(name: "diff", summary: "Show changes", argument: .file),
            .init(name: "restore", summary: "Discard changes", argument: .file),
            .init(name: "stash", summary: "Shelve changes", subcommands: [
                .init(name: "pop", summary: "Restore the last stash"),
                .init(name: "list", summary: "List stashes"),
            ]),
            .init(name: "worktree", summary: "Work on several branches at once", subcommands: [
                .init(name: "add", summary: "Create a worktree", argument: .directory),
                .init(name: "list", summary: "List worktrees"),
                .init(name: "remove", summary: "Remove a worktree"),
            ]),
        ]
    )

    static let npm = CompletionSpec(
        name: "npm",
        summary: "Node package manager",
        subcommands: [
            .init(name: "run", summary: "Run a script", argument: .generator(.init(
                id: "npm.scripts",
                command: "node -e \"try{const s=require('./package.json').scripts||{};Object.keys(s).forEach(k=>console.log(k))}catch(e){}\"",
                cacheSeconds: 30
            ))),
            .init(name: "install", summary: "Install dependencies"),
            .init(name: "ci", summary: "Clean install from the lockfile"),
            .init(name: "test", summary: "Run tests"),
            .init(name: "publish", summary: "Publish the package"),
        ]
    )

    static let docker = CompletionSpec(
        name: "docker",
        summary: "Containers",
        subcommands: [
            .init(name: "exec", summary: "Run a command in a container", argument: .generator(.init(
                id: "docker.containers",
                command: "docker ps --format '{{.Names}}'",
                cacheSeconds: 5
            ))),
            .init(name: "logs", summary: "Show a container's output", argument: .generator(.init(
                id: "docker.containers",
                command: "docker ps --format '{{.Names}}'",
                cacheSeconds: 5
            ))),
            .init(name: "compose", summary: "Run compose", subcommands: [
                .init(name: "up", summary: "Start services"),
                .init(name: "down", summary: "Stop services"),
                .init(name: "logs", summary: "Show service output"),
            ]),
            .init(name: "ps", summary: "List containers"),
            .init(name: "build", summary: "Build an image", argument: .directory),
        ]
    )

    static let cargo = CompletionSpec(
        name: "cargo",
        summary: "Rust toolchain",
        subcommands: [
            .init(name: "build", summary: "Compile", options: [.init(names: ["--release"], summary: "Optimised build")]),
            .init(name: "test", summary: "Run tests"),
            .init(name: "run", summary: "Build and run"),
            .init(name: "check", summary: "Type-check only"),
            .init(name: "clippy", summary: "Lint"),
            .init(name: "fmt", summary: "Format"),
            .init(name: "add", summary: "Add a dependency"),
        ]
    )

    static let make = CompletionSpec(
        name: "make",
        summary: "Run targets",
        argument: .generator(.init(
            id: "make.targets",
            command: "make -qp 2>/dev/null | awk -F':' '/^[a-zA-Z0-9][^$#\\\\/\\\\t=]*:([^=]|$)/ {print $1}' | sort -u | head -100",
            cacheSeconds: 30
        ))
    )
}

/// Runs a spec's generators and remembers their output, so the menu is built
/// from values that are already in hand.
@MainActor
final class GeneratorCache {
    static let shared = GeneratorCache()

    private struct Entry {
        let values: [String]
        let at: Date
    }

    private var entries: [String: Entry] = [:]
    private var running: Set<String> = []
    /// Everyone waiting on a run in flight, told when it lands; a prefetch
    /// and the menu often ask for the same run moments apart.
    private var waiters: [String: [() -> Void]] = [:]

    /// A run for this generator is in flight.
    func isLoading(_ generator: CompletionSpec.Generator, cwd: String) -> Bool {
        running.contains(key(generator, cwd: cwd))
    }

    /// Values already known for this generator in this folder, if any.
    func values(_ generator: CompletionSpec.Generator, cwd: String) -> [String] {
        entries[key(generator, cwd: cwd)].map(\.values) ?? []
    }

    /// Refreshes in the background when the cached values have aged out; the
    /// caller never waits.
    func refreshIfStale(_ generator: CompletionSpec.Generator, cwd: String, then: @escaping () -> Void = {}) {
        let key = key(generator, cwd: cwd)
        if let entry = entries[key], Date().timeIntervalSince(entry.at) < generator.cacheSeconds { return }
        waiters[key, default: []].append(then)
        guard running.insert(key).inserted else { return }
        let command = generator.command
        let timeout = generator.timeout
        DispatchQueue.global(qos: .userInitiated).async {
            let output = Self.run(command, in: cwd, timeout: timeout)
            let values = output.split(separator: "\n")
                .map { $0.trimmingCharacters(in: .whitespaces).trimmingCharacters(in: CharacterSet(charactersIn: "'")) }
                .filter { !$0.isEmpty }
            DispatchQueue.main.async {
                self.entries[key] = Entry(values: Array(values.prefix(300)), at: Date())
                self.running.remove(key)
                let waiting = self.waiters.removeValue(forKey: key) ?? []
                waiting.forEach { $0() }
            }
        }
    }

    private func key(_ generator: CompletionSpec.Generator, cwd: String) -> String {
        generator.perFolder ? generator.id + "\u{0}" + cwd : generator.id
    }

    private nonisolated static func run(_ command: String, in cwd: String, timeout: TimeInterval) -> String {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/sh")
        process.arguments = ["-c", command]
        process.currentDirectoryURL = URL(fileURLWithPath: cwd)
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = FileHandle.nullDevice
        do { try process.run() } catch { return "" }
        // A generator that hangs must not pile up behind the menu.
        DispatchQueue.global().asyncAfter(deadline: .now() + timeout) {
            if process.isRunning { process.terminate() }
        }
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        return String(decoding: data, as: UTF8.self)
    }
}
