import Foundation

/// Octet's own plugins: folders with a `plugin.json` manifest that add to
/// Octet itself. (The terminal engine has plugins of its own, managed
/// separately.) Octet ships some inside its bundle; the rest live in
/// `~/Library/Application Support/Octet/Plugins/<id>/`.
///
/// A plugin contributes data, and commands Octet runs on its behalf:
///
///     {
///       "id": "github-repos",
///       "name": "GitHub Repositories",
///       "version": "1.0.0",
///       "octet": 1,
///       "contributes": {
///         "completions": [{
///           "command": "git", "path": ["clone"],
///           "run": "/bin/sh \"$OCTET_PLUGIN_DIR/list-repos.sh\"",
///           "kind": "repository", "opensMenu": true
///         }]
///       }
///     }
///
/// `run` is a shell command, run in the pane's folder with
/// `OCTET_PLUGIN_DIR` set to the plugin's folder. It prints one value per
/// line, or `value<TAB>label<TAB>detail`.
struct OctetPluginManifest: Codable, Equatable {
    static let fileName = "plugin.json"
    /// The manifest format this Octet reads.
    static let formatVersion = 1

    let id: String
    let name: String
    var version: String = "0.0.0"
    var description: String?
    var author: String?
    /// The manifest format the plugin was written for.
    var octet: Int = 1
    var contributes: Contributions = .init()

    struct Contributions: Codable, Equatable {
        var completions: [CompletionContribution] = []
        /// Icons for what a pane is running, first matching rule wins.
        var runtimes: [RuntimeContribution] = []
        /// Executables that mean a pane's children aren't its runtime, like
        /// an editor whose language servers would otherwise match.
        var runtimeIgnore: [String] = []

        init(completions: [CompletionContribution] = [], runtimes: [RuntimeContribution] = [],
             runtimeIgnore: [String] = []) {
            self.completions = completions
            self.runtimes = runtimes
            self.runtimeIgnore = runtimeIgnore
        }

        init(from decoder: Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            completions = try container.decodeIfPresent([CompletionContribution].self, forKey: .completions) ?? []
            runtimes = try container.decodeIfPresent([RuntimeContribution].self, forKey: .runtimes) ?? []
            runtimeIgnore = try container.decodeIfPresent([String].self, forKey: .runtimeIgnore) ?? []
        }
    }

    /// A runtime, framework or language a pane can be running. `match` is
    /// regular expressions (case-insensitive) tried against each process
    /// under the pane's shell, as its arguments with every path shortened
    /// to its last component: `node /app/node_modules/.bin/vite --port 3`
    /// is matched as `node vite --port 3`.
    struct RuntimeContribution: Codable, Equatable {
        let id: String
        let name: String
        /// An image in the plugin's folder, SVG or PNG, drawn tinted.
        let icon: String
        /// The brand colour, as hex; black and white marks are adjusted to
        /// stay visible on the theme.
        var color: String?
        let match: [String]
        /// A more specific rule to use instead when the pane's project
        /// depends on a package: `[["@sveltejs/kit", "svelte"]]`.
        var refineByDependency: [[String]]?
    }

    /// Values for one argument of a command, from a command the plugin runs.
    struct CompletionContribution: Codable, Equatable {
        /// The command whose argument this completes, e.g. `git`.
        let command: String
        /// Subcommands leading to the argument, e.g. `["clone"]`.
        var path: [String] = []
        /// Shown beside the subcommand when the plugin adds it.
        var summary: String?
        let run: String
        /// How rows are drawn: repository, branch, file, directory, command.
        var kind: String?
        var cacheSeconds: Double?
        var timeoutSeconds: Double?
        /// False when the output doesn't depend on the pane's folder.
        var perFolder: Bool?
        /// Open the menu without Tab once the path has been typed.
        var opensMenu: Bool?
        /// Start fetching once the line starts with this, so a slow list is
        /// ready by the time the menu opens.
        var prefetchWhenTyping: String?

        init(command: String, path: [String] = [], summary: String? = nil, run: String, kind: String? = nil,
             cacheSeconds: Double? = nil, timeoutSeconds: Double? = nil, perFolder: Bool? = nil,
             opensMenu: Bool? = nil, prefetchWhenTyping: String? = nil) {
            self.command = command
            self.path = path
            self.summary = summary
            self.run = run
            self.kind = kind
            self.cacheSeconds = cacheSeconds
            self.timeoutSeconds = timeoutSeconds
            self.perFolder = perFolder
            self.opensMenu = opensMenu
            self.prefetchWhenTyping = prefetchWhenTyping
        }

        init(from decoder: Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            command = try container.decode(String.self, forKey: .command)
            path = try container.decodeIfPresent([String].self, forKey: .path) ?? []
            summary = try container.decodeIfPresent(String.self, forKey: .summary)
            run = try container.decode(String.self, forKey: .run)
            kind = try container.decodeIfPresent(String.self, forKey: .kind)
            cacheSeconds = try container.decodeIfPresent(Double.self, forKey: .cacheSeconds)
            timeoutSeconds = try container.decodeIfPresent(Double.self, forKey: .timeoutSeconds)
            perFolder = try container.decodeIfPresent(Bool.self, forKey: .perFolder)
            opensMenu = try container.decodeIfPresent(Bool.self, forKey: .opensMenu)
            prefetchWhenTyping = try container.decodeIfPresent(String.self, forKey: .prefetchWhenTyping)
        }
    }

    init(id: String, name: String, version: String = "0.0.0", description: String? = nil,
         author: String? = nil, octet: Int = 1, contributes: Contributions = .init()) {
        self.id = id
        self.name = name
        self.version = version
        self.description = description
        self.author = author
        self.octet = octet
        self.contributes = contributes
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(String.self, forKey: .id)
        name = try container.decode(String.self, forKey: .name)
        version = try container.decodeIfPresent(String.self, forKey: .version) ?? "0.0.0"
        description = try container.decodeIfPresent(String.self, forKey: .description)
        author = try container.decodeIfPresent(String.self, forKey: .author)
        octet = try container.decodeIfPresent(Int.self, forKey: .octet) ?? 1
        contributes = try container.decodeIfPresent(Contributions.self, forKey: .contributes) ?? .init()
    }
}

/// A plugin found on disk.
struct OctetPlugin: Identifiable, Equatable {
    let manifest: OctetPluginManifest
    let directory: String
    /// Shipped inside Octet, rather than installed by the person.
    let isBundled: Bool

    var id: String { manifest.id }
}

enum OctetPlugins {
    /// Where people install plugins.
    static func userDirectory(home: String = NSHomeDirectory()) -> String {
        "\(home)/Library/Application Support/Octet/Plugins"
    }

    /// Plugins in `directories`, later folders overriding earlier ones with
    /// the same id, plus a line for each folder that couldn't be loaded.
    static func discover(bundled: String?, user: String) -> (plugins: [OctetPlugin], problems: [String]) {
        var found: [String: OctetPlugin] = [:]
        var problems: [String] = []
        for (root, isBundled) in [(bundled, true), (user, false)] {
            guard let root else { continue }
            let names = ((try? FileManager.default.contentsOfDirectory(atPath: root)) ?? []).sorted()
            for name in names where !name.hasPrefix(".") {
                let directory = root + "/" + name
                let manifestPath = directory + "/" + OctetPluginManifest.fileName
                guard FileManager.default.fileExists(atPath: manifestPath) else { continue }
                switch load(manifestPath) {
                case .success(let manifest):
                    if let problem = validate(manifest) {
                        problems.append("\(name): \(problem)")
                    } else {
                        found[manifest.id] = OctetPlugin(manifest: manifest, directory: directory, isBundled: isBundled)
                    }
                case .failure(let error):
                    problems.append("\(name): \(error.localizedDescription)")
                }
            }
        }
        return (found.values.sorted { $0.manifest.name.localizedCaseInsensitiveCompare($1.manifest.name) == .orderedAscending },
                problems)
    }

    static func load(_ path: String) -> Result<OctetPluginManifest, Error> {
        Result {
            let data = try Data(contentsOf: URL(fileURLWithPath: path))
            return try JSONDecoder().decode(OctetPluginManifest.self, from: data)
        }
    }

    /// Why a manifest can't be used, or nil when it can.
    static func validate(_ manifest: OctetPluginManifest) -> String? {
        if manifest.id.range(of: "^[a-z0-9][a-z0-9._-]*$", options: .regularExpression) == nil {
            return "id must be lowercase letters, digits, dots, dashes or underscores"
        }
        if manifest.octet > OctetPluginManifest.formatVersion {
            return "needs a newer Octet (plugin format \(manifest.octet))"
        }
        let runtimeIds = Set(manifest.contributes.runtimes.map(\.id))
        for runtime in manifest.contributes.runtimes {
            if runtime.match.isEmpty { return "runtime \(runtime.id) matches nothing" }
            for pattern in runtime.match where (try? NSRegularExpression(pattern: pattern)) == nil {
                return "runtime \(runtime.id) has an invalid pattern: \(pattern)"
            }
            for pair in runtime.refineByDependency ?? [] where pair.count != 2 || !runtimeIds.contains(pair[1]) {
                return "runtime \(runtime.id) refines to an unknown runtime"
            }
        }
        for completion in manifest.contributes.completions {
            if completion.command.isEmpty || completion.command.contains(where: \.isWhitespace) {
                return "a completion names no single command"
            }
            if completion.run.trimmingCharacters(in: .whitespaces).isEmpty {
                return "a completion for \(completion.command) has nothing to run"
            }
        }
        return nil
    }

    /// The generator a contribution runs, named after its plugin so caches
    /// never collide.
    static func generator(_ contribution: OctetPluginManifest.CompletionContribution,
                          of plugin: OctetPlugin) -> CompletionSpec.Generator {
        let index = plugin.manifest.contributes.completions.firstIndex(of: contribution) ?? 0
        return CompletionSpec.Generator(
            id: "plugin.\(plugin.id).\(index)",
            command: "OCTET_PLUGIN_DIR=\(shellQuoted(plugin.directory)); export OCTET_PLUGIN_DIR\n" + contribution.run,
            cacheSeconds: contribution.cacheSeconds ?? 10,
            kind: kind(contribution.kind),
            perFolder: contribution.perFolder ?? true,
            timeout: min(max(contribution.timeoutSeconds ?? 2, 0.5), 30)
        )
    }

    static func kind(_ name: String?) -> Completion.Kind {
        switch name {
        case "repository": .repository
        case "file": .file
        case "directory": .directory
        case "command": .command
        case "flag": .flag
        default: .branch
        }
    }

    /// `spec` (or an empty one for `command`) with each plugin's argument
    /// values added where its path points, adding subcommands it names.
    static func applying(_ contributions: [(OctetPluginManifest.CompletionContribution, OctetPlugin)],
                         to spec: CompletionSpec?, command: String) -> CompletionSpec? {
        let mine = contributions.filter { $0.0.command == command }
        guard !mine.isEmpty else { return spec }
        var spec = spec ?? CompletionSpec(name: command)
        for (contribution, plugin) in mine {
            let argument = CompletionSpec.Argument.generator(generator(contribution, of: plugin))
            if contribution.path.isEmpty {
                spec.argument = argument
            } else {
                spec.subcommands = inserting(argument, at: contribution.path[...], summary: contribution.summary,
                                             into: spec.subcommands)
            }
        }
        return spec
    }

    private static func inserting(_ argument: CompletionSpec.Argument, at path: ArraySlice<String>,
                                  summary: String?, into subcommands: [CompletionSpec.Subcommand]) -> [CompletionSpec.Subcommand] {
        guard let name = path.first else { return subcommands }
        var subcommands = subcommands
        let index = subcommands.firstIndex { $0.name == name } ?? {
            subcommands.append(.init(name: name, summary: path.count == 1 ? summary ?? "" : ""))
            return subcommands.count - 1
        }()
        if path.count == 1 {
            subcommands[index].argument = argument
        } else {
            subcommands[index].subcommands = inserting(argument, at: path.dropFirst(), summary: summary,
                                                       into: subcommands[index].subcommands)
        }
        return subcommands
    }

    /// Whether the line has reached a point where a plugin wants its menu
    /// open without Tab: exactly its command and path, then a space.
    static func opensMenu(_ textBeforeCaret: String,
                          contributions: [OctetPluginManifest.CompletionContribution]) -> Bool {
        guard textBeforeCaret.last?.isWhitespace == true else { return false }
        let words = textBeforeCaret.split(whereSeparator: \.isWhitespace).map(String.init)
        return contributions.contains { $0.opensMenu == true && words == [$0.command] + $0.path }
    }

    private static func shellQuoted(_ value: String) -> String {
        "'" + value.replacingOccurrences(of: "'", with: "'\"'\"'") + "'"
    }
}

/// What a pane is running, as a plugin draws it.
struct RuntimeBadge: Equatable {
    let id: String
    let name: String
    /// Absolute path of the icon file.
    let iconPath: String
    let color: String?
}

/// Every enabled plugin's runtime rules, compiled, in priority order.
struct RuntimeMatcher {
    private struct Rule {
        let badge: RuntimeBadge
        let patterns: [NSRegularExpression]
        let refinements: [(dependency: String, id: String)]
    }

    private let rules: [Rule]
    private let byId: [String: RuntimeBadge]
    private let ignored: Set<String>

    init(plugins: [OctetPlugin]) {
        var rules: [Rule] = []
        var ignored: Set<String> = []
        for plugin in plugins {
            ignored.formUnion(plugin.manifest.contributes.runtimeIgnore.map { $0.lowercased() })
            for runtime in plugin.manifest.contributes.runtimes {
                let badge = RuntimeBadge(id: runtime.id, name: runtime.name,
                                         iconPath: plugin.directory + "/" + runtime.icon, color: runtime.color)
                let patterns = runtime.match.compactMap { try? NSRegularExpression(pattern: $0, options: .caseInsensitive) }
                let refinements = (runtime.refineByDependency ?? []).compactMap { pair in
                    pair.count == 2 ? (pair[0], pair[1]) : nil
                }
                rules.append(Rule(badge: badge, patterns: patterns, refinements: refinements))
            }
        }
        self.rules = rules
        self.ignored = ignored
        byId = Dictionary(rules.map { ($0.badge.id, $0.badge) }) { first, _ in first }
    }

    var isEmpty: Bool { rules.isEmpty }

    /// A process's arguments with each path cut to its last component.
    static func words(_ arguments: String) -> String {
        arguments.split(whereSeparator: \.isWhitespace)
            .map { (String($0) as NSString).lastPathComponent }
            .joined(separator: " ")
    }

    /// The first rule, in priority order, that any of `commands` (already
    /// passed through `words`) matches. `dependencies` is asked only when a
    /// rule wants to refine by the project's packages.
    func match(commands: [String], dependencies: () -> Set<String> = { [] }) -> RuntimeBadge? {
        guard !commands.isEmpty else { return nil }
        let executables = commands.compactMap { $0.split(separator: " ").first.map { $0.lowercased() } }
        if executables.contains(where: ignored.contains) { return nil }
        for rule in rules {
            let hit = commands.contains { command in
                let range = NSRange(command.startIndex..., in: command)
                return rule.patterns.contains { $0.firstMatch(in: command, range: range) != nil }
            }
            guard hit else { continue }
            if !rule.refinements.isEmpty {
                let installed = dependencies()
                if let refined = rule.refinements.first(where: { installed.contains($0.dependency) }),
                   let badge = byId[refined.id] {
                    return badge
                }
            }
            return rule.badge
        }
        return nil
    }

    /// The packages the nearest `package.json` at or above `directory` lists.
    static func packageDependencies(from directory: String) -> Set<String> {
        var url = URL(fileURLWithPath: directory)
        while url.path != "/" {
            let file = url.appendingPathComponent("package.json")
            if let data = try? Data(contentsOf: file),
               let json = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] {
                let sections = ["dependencies", "devDependencies", "peerDependencies"]
                return Set(sections.flatMap { (json[$0] as? [String: Any])?.keys.map { $0 } ?? [] })
            }
            url.deleteLastPathComponent()
        }
        return []
    }
}
