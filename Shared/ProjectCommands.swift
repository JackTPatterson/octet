import Foundation

/// What the folder you're standing in can actually run: npm scripts, make
/// targets, just recipes, compose services, and the aliases your shell and
/// git already know. Read from the project's own files, so the suggestions
/// are real rather than generic.
enum ProjectCommands {
    struct Entry: Equatable {
        let command: String
        /// Where it came from, shown beside the suggestion.
        let source: String
    }

    /// Everything runnable in `directory`, ready to offer as completions.
    static func all(in directory: String, home: String = NSHomeDirectory()) -> [Entry] {
        var entries: [Entry] = []
        entries += npmScripts(in: directory)
        entries += makeTargets(in: directory)
        entries += justRecipes(in: directory)
        entries += composeServices(in: directory)
        entries += aliases(home: home)
        return entries
    }

    // MARK: - Project files

    static func npmScripts(in directory: String) -> [Entry] {
        guard let data = FileManager.default.contents(atPath: directory + "/package.json") else { return [] }
        // The project's own package manager, from its lockfile.
        let files = FileManager.default
        let runner = files.fileExists(atPath: directory + "/pnpm-lock.yaml") ? "pnpm run"
            : files.fileExists(atPath: directory + "/yarn.lock") ? "yarn"
            : files.fileExists(atPath: directory + "/bun.lockb") || files.fileExists(atPath: directory + "/bun.lock") ? "bun run"
            : "npm run"
        return parseNpmScripts(data, runner: runner)
    }

    static func parseNpmScripts(_ data: Data, runner: String = "npm run") -> [Entry] {
        guard let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let scripts = object["scripts"] as? [String: Any] else { return [] }
        // npm and its friends all run scripts the same way.
        return scripts.keys.sorted().map { Entry(command: "\(runner) \($0)", source: "package.json") }
    }

    static func makeTargets(in directory: String) -> [Entry] {
        for name in ["Makefile", "makefile", "GNUmakefile"] {
            guard let text = try? String(contentsOfFile: directory + "/" + name, encoding: .utf8) else { continue }
            return parseMakeTargets(text)
        }
        return []
    }

    /// Target lines look like `build: deps`, skipping variables and patterns.
    static func parseMakeTargets(_ text: String) -> [Entry] {
        var targets: [String] = []
        var seen = Set<String>()
        for line in text.components(separatedBy: "\n") {
            guard !line.hasPrefix("\t"), !line.hasPrefix("#"), !line.hasPrefix("."),
                  let colon = line.firstIndex(of: ":") else { continue }
            let name = String(line[..<colon]).trimmingCharacters(in: .whitespaces)
            guard !name.isEmpty, !name.contains(" "), !name.contains("="), !name.contains("%"),
                  !name.contains("$"), seen.insert(name).inserted else { continue }
            targets.append(name)
        }
        return targets.map { Entry(command: "make \($0)", source: "Makefile") }
    }

    static func justRecipes(in directory: String) -> [Entry] {
        for name in ["justfile", "Justfile", ".justfile"] {
            guard let text = try? String(contentsOfFile: directory + "/" + name, encoding: .utf8) else { continue }
            return parseJustRecipes(text)
        }
        return []
    }

    /// Recipes are `name:` or `name arg:` at the start of a line.
    static func parseJustRecipes(_ text: String) -> [Entry] {
        var recipes: [String] = []
        var seen = Set<String>()
        for line in text.components(separatedBy: "\n") {
            guard !line.hasPrefix(" "), !line.hasPrefix("\t"), !line.hasPrefix("#"),
                  !line.contains(":="), // `set shell := [...]` is an assignment
                  let colon = line.firstIndex(of: ":") else { continue }
            let head = String(line[..<colon]).trimmingCharacters(in: .whitespaces)
            guard let name = head.split(separator: " ").first.map(String.init),
                  !name.isEmpty, !name.contains("="), seen.insert(name).inserted else { continue }
            recipes.append(name)
        }
        return recipes.map { Entry(command: "just \($0)", source: "justfile") }
    }

    static func composeServices(in directory: String) -> [Entry] {
        for name in ["docker-compose.yml", "docker-compose.yaml", "compose.yml", "compose.yaml"] {
            guard let text = try? String(contentsOfFile: directory + "/" + name, encoding: .utf8) else { continue }
            return parseComposeServices(text)
        }
        return []
    }

    /// Service names are the keys indented once under `services:`.
    static func parseComposeServices(_ text: String) -> [Entry] {
        var services: [String] = []
        var inServices = false
        var indent: Int?
        for line in text.components(separatedBy: "\n") {
            if line.hasPrefix("services:") {
                inServices = true
                continue
            }
            guard inServices else { continue }
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            guard !trimmed.isEmpty, !trimmed.hasPrefix("#") else { continue }
            let leading = line.prefix { $0 == " " }.count
            if leading == 0 { break }
            if indent == nil { indent = leading }
            guard leading == indent, trimmed.hasSuffix(":") else { continue }
            services.append(String(trimmed.dropLast()))
        }
        return services.map { Entry(command: "docker compose up \($0)", source: "compose") }
    }

    // MARK: - Aliases

    /// Shell aliases and git aliases, which behave like commands of your own.
    static func aliases(home: String = NSHomeDirectory()) -> [Entry] {
        var entries: [Entry] = []
        for file in [".zshrc", ".bashrc", ".bash_profile", ".config/fish/config.fish"] {
            guard let text = try? String(contentsOfFile: "\(home)/\(file)", encoding: .utf8) else { continue }
            entries += parseShellAliases(text).map { Entry(command: $0, source: "alias") }
        }
        if let text = try? String(contentsOfFile: "\(home)/.gitconfig", encoding: .utf8) {
            entries += parseGitAliases(text).map { Entry(command: "git \($0)", source: "git alias") }
        }
        var seen = Set<String>()
        return entries.filter { seen.insert($0.command).inserted }
    }

    static func parseShellAliases(_ text: String) -> [String] {
        var names: [String] = []
        for line in text.components(separatedBy: "\n") {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            guard trimmed.hasPrefix("alias "), let equals = trimmed.firstIndex(of: "=") else { continue }
            let name = String(trimmed[trimmed.index(trimmed.startIndex, offsetBy: 6)..<equals])
                .trimmingCharacters(in: .whitespaces)
            guard !name.isEmpty, !name.contains(" ") else { continue }
            names.append(name)
        }
        return names
    }

    /// `[alias]` entries in a gitconfig.
    static func parseGitAliases(_ text: String) -> [String] {
        var names: [String] = []
        var inAliases = false
        for line in text.components(separatedBy: "\n") {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if trimmed.hasPrefix("[") {
                inAliases = trimmed.hasPrefix("[alias]")
                continue
            }
            guard inAliases, let equals = trimmed.firstIndex(of: "="), !trimmed.hasPrefix("#") else { continue }
            let name = String(trimmed[..<equals]).trimmingCharacters(in: .whitespaces)
            guard !name.isEmpty, !name.contains(" ") else { continue }
            names.append(name)
        }
        return names
    }
}
