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

    var id: String { "\(origin.label)|\(insertion)|\(name)" }
    var hasChildren: Bool { !children.isEmpty }

    init(
        name: String,
        insertion: String? = nil,
        summary: String = "",
        origin: Origin = .builtIn,
        argumentHint: String = "",
        children: [SlashCommand] = []
    ) {
        self.name = name
        self.insertion = insertion ?? "/" + name
        self.summary = summary
        self.origin = origin
        self.argumentHint = argumentHint
        self.children = children
    }

    /// This command and every descendant, for searching the whole tree.
    var flattened: [SlashCommand] {
        [self] + children.flatMap(\.flattened)
    }
}

/// What the machine actually has, so submenus list real arguments rather
/// than guesses: configured MCP servers, cached models, agents, and so on.
struct SlashContext: Equatable {
    var mcpServers: [String] = []
    var agents: [(name: String, summary: String)] = []
    var outputStyles: [String] = []
    /// Codex ships its model list with the reasoning levels each supports.
    var models: [(id: String, summary: String, efforts: [String])] = []
    var directories: [String] = []
    var sessions: [(id: String, label: String)] = []

    static func == (lhs: SlashContext, rhs: SlashContext) -> Bool {
        lhs.mcpServers == rhs.mcpServers
            && lhs.agents.map(\.name) == rhs.agents.map(\.name)
            && lhs.outputStyles == rhs.outputStyles
            && lhs.models.map(\.id) == rhs.models.map(\.id)
            && lhs.directories == rhs.directories
            && lhs.sessions.map(\.id) == rhs.sessions.map(\.id)
    }

    /// Reads the agents' own config. File reads only, so it stays cheap
    /// enough to refresh whenever the menu opens.
    static func load(agent: String?, cwd: String?, home: String = NSHomeDirectory()) -> SlashContext {
        var context = SlashContext()
        let kind = AgentBrand.forAgent(agent)?.id ?? agent ?? ""
        switch kind {
        case "codex":
            context.mcpServers = codexServers(home: home)
            context.models = codexModels(home: home)
        case "claude":
            context.mcpServers = claudeServers(cwd: cwd, home: home)
            context.models = [
                ("default", "Let Claude Code choose", []),
                ("opus", "Claude Opus", []),
                ("sonnet", "Claude Sonnet", []),
                ("haiku", "Claude Haiku", []),
                ("opusplan", "Opus for planning, Sonnet to execute", []),
            ]
            context.agents = markdownEntries(in: "\(home)/.claude/agents")
                + (cwd.map { markdownEntries(in: "\($0)/.claude/agents") } ?? [])
            context.outputStyles = ["default", "explanatory", "learning"]
                + markdownEntries(in: "\(home)/.claude/output-styles").map(\.name)
        default:
            // Any other agent: its own folders, nothing vendor-specific.
            if let host = AgentHosts.host(kind, home: home) {
                context.agents = markdownEntries(in: "\(host.home)/agents")
            }
        }
        return context
    }

    /// `~/.claude.json` holds user servers; a project adds `.mcp.json`.
    static func claudeServers(cwd: String?, home: String = NSHomeDirectory()) -> [String] {
        var names: [String] = []
        for path in [("\(home)/.claude.json"), cwd.map { "\($0)/.mcp.json" }].compactMap({ $0 }) {
            guard let data = try? Data(contentsOf: URL(fileURLWithPath: path)),
                  let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let servers = object["mcpServers"] as? [String: Any] else { continue }
            names += servers.keys
        }
        return Array(Set(names)).sorted()
    }

    /// `[mcp_servers.<name>]` tables in Codex's config.
    static func codexServers(home: String = NSHomeDirectory()) -> [String] {
        let text = (try? String(contentsOfFile: "\(home)/.codex/config.toml", encoding: .utf8)) ?? ""
        return parseCodexServers(text)
    }

    static func parseCodexServers(_ toml: String) -> [String] {
        toml.components(separatedBy: "\n").compactMap { line in
            let text = line.trimmingCharacters(in: .whitespaces)
            guard text.hasPrefix("[mcp_servers."), text.hasSuffix("]") else { return nil }
            let name = text.dropFirst("[mcp_servers.".count).dropLast()
            return name.isEmpty ? nil : String(name).trimmingCharacters(in: CharacterSet(charactersIn: "\""))
        }
    }

    static func codexModels(home: String = NSHomeDirectory()) -> [(id: String, summary: String, efforts: [String])] {
        guard let data = try? Data(contentsOf: URL(fileURLWithPath: "\(home)/.codex/models_cache.json")) else { return [] }
        return parseCodexModels(data)
    }

    static func parseCodexModels(_ data: Data) -> [(id: String, summary: String, efforts: [String])] {
        guard let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let models = object["models"] as? [[String: Any]] else { return [] }
        return models.compactMap { model in
            guard let slug = model["slug"] as? String else { return nil }
            let efforts = (model["supported_reasoning_levels"] as? [[String: Any]])?
                .compactMap { $0["effort"] as? String } ?? []
            let summary = model["description"] as? String ?? model["display_name"] as? String ?? ""
            return (slug, summary, efforts)
        }
    }

    /// `name` and `description` of every markdown file in a folder.
    static func markdownEntries(in directory: String) -> [(name: String, summary: String)] {
        let names = (try? FileManager.default.contentsOfDirectory(atPath: directory)) ?? []
        return names.filter { $0.hasSuffix(".md") }.sorted().map { file in
            let text = (try? String(contentsOfFile: "\(directory)/\(file)", encoding: .utf8)) ?? ""
            let described = AgentLibrary.describe(text)
            return (described.name ?? String(file.dropLast(3)), described.summary)
        }
    }
}

enum SlashCommands {
    // MARK: Built-ins

    /// Claude Code's built-ins. `arguments` names the submenu each one opens.
    static func claudeBuiltIns(_ context: SlashContext) -> [SlashCommand] {
        [
            command("add-dir", "Add a working directory", hint: "<path>",
                    children: context.directories.map { path in
                        SlashCommand(name: (path as NSString).lastPathComponent, insertion: "/add-dir \(path)",
                                     summary: path, origin: .argument)
                    }),
            command("agents", "Manage agents and subagents",
                    children: context.agents.map { agent in
                        SlashCommand(name: agent.name, insertion: "/agents \(agent.name)",
                                     summary: agent.summary, origin: .argument)
                    }),
            command("clear", "Clear the conversation"),
            command("compact", "Summarize the conversation to free context", hint: "<instructions>"),
            command("config", "Open settings"),
            command("context", "Show what is using the context window"),
            command("cost", "Show token usage and cost"),
            command("doctor", "Check the installation's health"),
            command("exit", "Quit Claude Code"),
            command("export", "Export the conversation", hint: "<file>"),
            command("help", "List commands"),
            command("hooks", "Configure hooks"),
            command("init", "Create a CLAUDE.md for this project"),
            command("mcp", "Manage MCP servers", children: serverChildren(context, command: "/mcp")),
            command("memory", "Edit memory files"),
            command("model", "Change the model", hint: "<model>", children: modelChildren(context, command: "/model")),
            command("output-style", "Change the output style",
                    children: context.outputStyles.map { style in
                        SlashCommand(name: style, insertion: "/output-style \(style)", origin: .argument)
                    }),
            command("permissions", "Manage tool permissions"),
            command("plugin", "Manage plugins"),
            command("pr-comments", "Read pull request comments"),
            command("release-notes", "Show what changed"),
            command("resume", "Resume a past conversation",
                    children: context.sessions.map { session in
                        SlashCommand(name: session.label, insertion: "/resume \(session.id)",
                                     summary: session.id, origin: .argument)
                    }),
            command("review", "Review a pull request", hint: "<pr>"),
            command("rewind", "Rewind the conversation or the code"),
            command("status", "Show account and system status"),
            command("statusline", "Set up the status line"),
            command("todos", "Show the todo list"),
            command("usage", "Show plan usage limits"),
            command("vim", "Toggle vim bindings"),
        ]
    }

    /// The built-in table for an agent, empty when Octet doesn't ship one.
    static func builtIns(for agent: String, context: SlashContext) -> [SlashCommand] {
        switch agent {
        case "claude": claudeBuiltIns(context)
        case "codex": codexBuiltIns(context)
        default: []
        }
    }

    static func codexBuiltIns(_ context: SlashContext) -> [SlashCommand] {
        [
            command("approvals", "Change what Codex may do without asking",
                    children: ["untrusted", "on-failure", "on-request", "never"].map { mode in
                        SlashCommand(name: mode, insertion: "/approvals \(mode)", origin: .argument)
                    }),
            command("compact", "Summarize the conversation to free context"),
            command("diff", "Show the working tree diff"),
            command("init", "Create an AGENTS.md for this project"),
            command("mcp", "Manage MCP servers", children: serverChildren(context, command: "/mcp")),
            command("mention", "Mention a file", hint: "<file>"),
            command("model", "Change the model and reasoning effort", hint: "<model>",
                    children: modelChildren(context, command: "/model")),
            command("new", "Start a new conversation"),
            command("quit", "Quit Codex"),
            command("review", "Review the current changes"),
            command("status", "Show session status"),
            command("undo", "Undo the last change"),
        ]
    }

    private static func command(
        _ name: String,
        _ summary: String,
        hint: String = "",
        children: [SlashCommand] = []
    ) -> SlashCommand {
        SlashCommand(name: name, summary: summary, argumentHint: hint, children: children)
    }

    private static func serverChildren(_ context: SlashContext, command: String) -> [SlashCommand] {
        context.mcpServers.map { server in
            SlashCommand(name: server, insertion: "\(command) \(server)", summary: "MCP server", origin: .argument)
        }
    }

    /// Models, each with its reasoning levels as a further submenu.
    private static func modelChildren(_ context: SlashContext, command: String) -> [SlashCommand] {
        context.models.map { model in
            SlashCommand(
                name: model.id,
                insertion: "\(command) \(model.id)",
                summary: model.summary,
                origin: .argument,
                children: model.efforts.map { effort in
                    SlashCommand(name: effort, insertion: "\(command) \(model.id) \(effort)",
                                 summary: "reasoning effort", origin: .argument)
                }
            )
        }
    }

    // MARK: Tree

    /// Every command for an agent: built-ins, the user's and the project's
    /// prompt files, and each plugin's commands, grouped into submenus.
    static func all(
        agent: String?,
        cwd: String?,
        context: SlashContext = SlashContext(),
        home: String = NSHomeDirectory()
    ) -> [SlashCommand] {
        let kind = AgentBrand.forAgent(agent)?.id ?? agent ?? ""
        guard let host = AgentHosts.host(kind, home: home) else { return [] }
        // Built-ins are per-agent; an agent Octet has no table for still gets
        // its own prompt files and plugin commands.
        var commands = builtIns(for: kind, context: context)
        var extra = prompts(in: host.promptsDirectory, origin: .user)
        if let cwd {
            let directory = kind == "codex" ? "\(cwd)/.codex/prompts" : "\(cwd)/.claude/commands"
            extra += prompts(in: directory, origin: .project)
        }
        extra += pluginCommands(host: host)
        // Later sources shadow a built-in of the same name.
        let overridden = Set(extra.map(\.name))
        commands = commands.filter { !overridden.contains($0.name) } + extra
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
            guard let match = FuzzyMatcher.match(needle, in: haystack) else {
                guard !command.summary.isEmpty, FuzzyMatcher.match(needle, in: command.summary) != nil else { return nil }
                return (command, -1000)
            }
            let exact = haystack.lowercased().hasPrefix(needle.lowercased()) ? 500 : 0
            return (command, match.score + exact)
        }
        .sorted { first, second in
            first.1 == second.1
                ? first.0.insertion.localizedCaseInsensitiveCompare(second.0.insertion) == .orderedAscending
                : first.1 > second.1
        }
        .map(\.0)
    }
}
