import Foundation

/// The slash commands an agent offers: its built-ins plus the prompt files
/// the user and plugins provide. Octet lists them itself so `/` opens a native
/// menu instead of the agent's in-terminal one. Commands that take a known
/// set of arguments — `/mcp`, `/model`, namespaced prompts, plugins with
/// several commands — carry children and open a submenu.
struct SlashCommand: Identifiable, Equatable {
    enum Origin: Equatable {
        case builtIn
        case user
        case project
        case plugin(String)
        case argument

        var label: String {
            switch self {
            case .builtIn, .argument: ""
            case .user: "user"
            case .project: "project"
            case .plugin(let name): name
            }
        }
    }

    /// What this level shows, e.g. `git` or `add`.
    let name: String
    /// The whole text typed into the prompt, leading slash included.
    let insertion: String
    var summary: String = ""
    var origin: Origin = .builtIn
    /// Shown when the command takes free text, e.g. `<instructions>`.
    var argumentHint: String = ""
    var children: [SlashCommand] = []
    /// Other names typing matches, as the agent's own menu allows
    /// (`/clear` for `/new`).
    var aliases: [String] = []
    /// Who carries the command out in Octet's chat view.
    var handling: Handling = .agent

    enum Handling: Equatable {
        /// Sent to the agent, which runs it headless.
        case agent
        /// Octet does it: opens its own menu, starts a conversation, and so on.
        case octet
    }

    var id: String { "\(origin.label)|\(insertion)|\(name)" }
    var hasChildren: Bool { !children.isEmpty }

    init(
        name: String,
        insertion: String? = nil,
        summary: String = "",
        origin: Origin = .builtIn,
        argumentHint: String = "",
        children: [SlashCommand] = [],
        aliases: [String] = [],
        handling: Handling = .agent
    ) {
        self.name = name
        self.insertion = insertion ?? "/" + name
        self.summary = summary
        self.origin = origin
        self.argumentHint = argumentHint
        self.children = children
        self.aliases = aliases
        self.handling = handling
    }

    /// This command and every descendant, for searching the whole tree.
    var flattened: [SlashCommand] {
        [self] + children.flatMap(\.flattened)
    }
}

enum SlashCommands {
    // MARK: Tree

    /// An agent's commands on disk: the user's and the project's prompt
    /// files, and each plugin's commands, grouped into submenus.
    static func all(
        agent: String?,
        cwd: String?,
        home: String = NSHomeDirectory()
    ) -> [SlashCommand] {
        let kind = AgentBrand.forAgent(agent)?.id ?? agent ?? ""
        guard let host = AgentHosts.host(kind, home: home) else { return [] }
        // The agent's prompt files and plugin commands, read from disk.
        var commands = prompts(in: host.promptsDirectory, origin: .user)
        if let cwd {
            let directory = kind == "codex" ? "\(cwd)/.codex/prompts" : "\(cwd)/.claude/commands"
            commands += prompts(in: directory, origin: .project)
        }
        commands += pluginCommands(host: host)
        return group(commands).sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
    }

    /// Turns `git:amend` style names into a `/git` submenu, and gathers a
    /// plugin's commands under the plugin's own entry.
    static func group(_ commands: [SlashCommand]) -> [SlashCommand] {
        var plain: [SlashCommand] = []
        var namespaces: [String: [SlashCommand]] = [:]
        var order: [String] = []
        var plugins: [String: [SlashCommand]] = [:]
        var pluginOrder: [String] = []

        for command in commands {
            if case .plugin(let plugin) = command.origin {
                if plugins[plugin] == nil { pluginOrder.append(plugin) }
                plugins[plugin, default: []].append(command)
                continue
            }
            guard let separator = command.name.firstIndex(of: ":") else {
                plain.append(command)
                continue
            }
            let namespace = String(command.name[..<separator])
            let rest = String(command.name[command.name.index(after: separator)...])
            if namespaces[namespace] == nil { order.append(namespace) }
            namespaces[namespace, default: []].append(SlashCommand(
                name: rest, insertion: command.insertion, summary: command.summary,
                origin: command.origin, argumentHint: command.argumentHint, children: command.children
            ))
        }

        for namespace in order {
            let children = group(namespaces[namespace] ?? [])
            plain.append(SlashCommand(
                name: namespace, insertion: "/" + namespace,
                summary: "\(children.count) command\(children.count == 1 ? "" : "s")",
                origin: children.first?.origin ?? .user, children: children
            ))
        }
        for plugin in pluginOrder {
            let commands = plugins[plugin] ?? []
            // A plugin with one command doesn't deserve a submenu.
            if commands.count == 1 {
                plain.append(commands[0])
            } else {
                plain.append(SlashCommand(
                    name: plugin, insertion: "/" + plugin,
                    summary: "\(commands.count) commands", origin: .plugin(plugin),
                    children: group(commands.map {
                        SlashCommand(name: $0.name, insertion: $0.insertion, summary: $0.summary,
                                     origin: .argument, argumentHint: $0.argumentHint)
                    })
                ))
            }
        }
        return plain
    }

    /// Markdown prompt files. Nested folders namespace their commands with
    /// `:`, the way both CLIs read them.
    static func prompts(in directory: String, origin: SlashCommand.Origin, prefix: String = "") -> [SlashCommand] {
        let names = (try? FileManager.default.contentsOfDirectory(atPath: directory)) ?? []
        var commands: [SlashCommand] = []
        for name in names.sorted() {
            let path = "\(directory)/\(name)"
            var isDirectory: ObjCBool = false
            guard FileManager.default.fileExists(atPath: path, isDirectory: &isDirectory) else { continue }
            if isDirectory.boolValue {
                commands += prompts(in: path, origin: origin, prefix: prefix + name + ":")
                continue
            }
            guard name.hasSuffix(".md") else { continue }
            let text = (try? String(contentsOfFile: path, encoding: .utf8)) ?? ""
            let full = prefix + String(name.dropLast(3))
            commands.append(SlashCommand(
                name: full,
                insertion: "/" + full,
                summary: AgentLibrary.describe(text).summary,
                origin: origin,
                argumentHint: argumentHint(in: text)
            ))
        }
        return commands
    }

    /// Commands each installed plugin contributes, from its `commands/` folder.
    static func pluginCommands(host: AgentHost) -> [SlashCommand] {
        let cache = "\(host.home)/plugins/cache"
        let manager = FileManager.default
        guard let marketplaces = try? manager.contentsOfDirectory(atPath: cache) else { return [] }
        var commands: [SlashCommand] = []
        for marketplace in marketplaces {
            let marketplacePath = "\(cache)/\(marketplace)"
            for plugin in (try? manager.contentsOfDirectory(atPath: marketplacePath)) ?? [] {
                let pluginPath = "\(marketplacePath)/\(plugin)"
                // Plugins are cached per version: <plugin>/<version>/commands.
                for version in (try? manager.contentsOfDirectory(atPath: pluginPath)) ?? [] {
                    let directory = "\(pluginPath)/\(version)/commands"
                    guard manager.fileExists(atPath: directory) else { continue }
                    commands += prompts(in: directory, origin: .plugin(plugin))
                }
            }
        }
        return commands
    }

    /// `argument-hint:` from a prompt file's frontmatter, which both CLIs use.
    static func argumentHint(in text: String) -> String {
        for line in text.components(separatedBy: "\n").prefix(20) {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            guard trimmed.hasPrefix("argument-hint:") else { continue }
            return trimmed.dropFirst("argument-hint:".count)
                .trimmingCharacters(in: .whitespaces)
                .trimmingCharacters(in: CharacterSet(charactersIn: "\"'"))
        }
        return ""
    }

    // MARK: Search

    /// Filters one level for the typed text. With a query it searches the
    /// whole subtree, so `amend` finds `/git:amend` from the top.
    static func matching(_ query: String, in commands: [SlashCommand]) -> [SlashCommand] {
        let needle = query.trimmingCharacters(in: .whitespaces)
        guard !needle.isEmpty else { return commands }
        let searchable = commands.flatMap(\.flattened)
        var seen = Set<String>()
        return searchable.compactMap { command -> (SlashCommand, Int)? in
            guard seen.insert(command.id).inserted else { return nil }
            let haystack = command.insertion.hasPrefix("/") ? String(command.insertion.dropFirst()) : command.insertion
            // The best of the name and its aliases.
            let scores = ([haystack] + command.aliases).compactMap { name -> Int? in
                guard let match = FuzzyMatcher.match(needle, in: name) else { return nil }
                return match.score + (name.lowercased().hasPrefix(needle.lowercased()) ? 500 : 0)
            }
            guard let best = scores.max() else {
                guard !command.summary.isEmpty, FuzzyMatcher.match(needle, in: command.summary) != nil else { return nil }
                return (command, -1000)
            }
            return (command, best)
        }
        .sorted { first, second in
            first.1 == second.1
                ? first.0.insertion.localizedCaseInsensitiveCompare(second.0.insertion) == .orderedAscending
                : first.1 > second.1
        }
        .map(\.0)
    }
}

// MARK: - Octet's chat view

extension SlashCommands {
    /// Claude Code's commands, as its `initialize` answer lists them. Model,
    /// effort and a fresh start are Octet's pickers and tabs in its chat view;
    /// internal ones (`__…`) aren't for people.
    static func claudePublished(_ list: [[String: Any]]) -> [SlashCommand] {
        list.compactMap { command in
            guard let name = command["name"] as? String, !name.hasPrefix("__") else { return nil }
            return SlashCommand(name: name, summary: command["description"] as? String ?? "",
                                argumentHint: command["argumentHint"] as? String ?? "",
                                handling: ["model", "effort", "clear"].contains(name) ? .octet : .agent)
        }
    }

    /// Codex's app server carries out these; Octet offers them under the
    /// names Codex's own menu uses.
    static let codexOctetCommands: [SlashCommand] = [
        SlashCommand(name: "compact", summary: "Summarize the conversation to free context", handling: .octet),
        SlashCommand(name: "model", summary: "Change the model and reasoning effort", handling: .octet),
        SlashCommand(name: "new", summary: "Start a new conversation", handling: .octet),
        SlashCommand(name: "permissions", summary: "Change what Codex may do without asking", aliases: ["approvals"], handling: .octet),
        SlashCommand(name: "quit", summary: "Close this conversation", aliases: ["exit"], handling: .octet),
        SlashCommand(name: "rename", summary: "Rename the conversation", argumentHint: "<name>", handling: .octet),
        SlashCommand(name: "review", summary: "Review the current changes, or against a branch", argumentHint: "[branch]", handling: .octet),
    ]

    /// The command a message starts with, by name or alias, and the rest of
    /// the line as its arguments.
    static func invoked(_ text: String, in commands: [SlashCommand]) -> (command: SlashCommand, arguments: String)? {
        guard text.hasPrefix("/") else { return nil }
        let line = text.dropFirst()
        let name = String(line.prefix { !$0.isWhitespace })
        guard !name.isEmpty,
              let command = commands.first(where: { $0.name == name || $0.aliases.contains(name) }) else { return nil }
        return (command, line.dropFirst(name.count).trimmingCharacters(in: .whitespacesAndNewlines))
    }
}
