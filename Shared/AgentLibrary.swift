import Foundation

/// Octet's shared, vendor-neutral library of skills and prompts, kept in
/// `~/.agents` (the convention Claude's `skills` symlinks already follow).
/// Items live here once and are symlinked into each agent host, so editing a
/// prompt or skill updates every agent that has it.
enum AgentLibrary {
    enum Kind: String, CaseIterable {
        case skill, prompt

        var folder: String { self == .skill ? "skills" : "prompts" }
        var title: String { self == .skill ? "Skills" : "Prompts" }
    }

    /// `OCTET_LIBRARY_DIR` overrides the root, for tests.
    static func root(home: String = NSHomeDirectory()) -> String {
        ProcessInfo.processInfo.environment["OCTET_LIBRARY_DIR"] ?? "\(home)/.agents"
    }

    static func directory(_ kind: Kind, home: String = NSHomeDirectory()) -> String {
        "\(root(home: home))/\(kind.folder)"
    }

    /// A skill folder or prompt file in the library.
    struct Item: Identifiable, Equatable {
        let kind: Kind
        let slug: String
        var name: String
        var summary: String
        /// Path in the library: a folder for skills, a `.md` file for prompts.
        let path: String
        /// Host ids this item is currently installed in.
        var installedIn: Set<String> = []

        var id: String { "\(kind.rawValue):\(slug)" }
        /// The file holding the item's text.
        var contentPath: String { kind == .skill ? "\(path)/SKILL.md" : path }
    }

    // MARK: - Reading

    static func items(_ kind: Kind, hosts: [AgentHost], home: String = NSHomeDirectory()) -> [Item] {
        let directory = directory(kind, home: home)
        let names = (try? FileManager.default.contentsOfDirectory(atPath: directory)) ?? []
        return names.compactMap { name -> Item? in
            let path = "\(directory)/\(name)"
            switch kind {
            case .skill:
                var isDirectory: ObjCBool = false
                guard FileManager.default.fileExists(atPath: "\(path)/SKILL.md", isDirectory: &isDirectory) else { return nil }
                return item(kind: .skill, slug: name, path: path, hosts: hosts)
            case .prompt:
                guard name.hasSuffix(".md") else { return nil }
                return item(kind: .prompt, slug: String(name.dropLast(3)), path: path, hosts: hosts)
            }
        }
        .sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
    }

    private static func item(kind: Kind, slug: String, path: String, hosts: [AgentHost]) -> Item {
        var item = Item(kind: kind, slug: slug, name: slug, summary: "", path: path)
        let text = (try? String(contentsOfFile: item.contentPath, encoding: .utf8)) ?? ""
        let described = describe(text)
        item.name = described.name ?? slug
        item.summary = described.summary
        item.installedIn = Set(hosts.filter { isInstalled(item, in: $0) }.map(\.id))
        return item
    }

    /// Reads `name`/`description` from YAML frontmatter, else the first
    /// heading and paragraph.
    static func describe(_ text: String) -> (name: String?, summary: String) {
        var name: String?
        var summary = ""
        let lines = text.components(separatedBy: "\n")
        if lines.first?.trimmingCharacters(in: .whitespaces) == "---" {
            /// Collecting the indented body of a `key: |` block scalar.
            var blockKey: String?
            var block: [String] = []
            func finishBlock() {
                guard let key = blockKey else { return }
                let text = block.joined(separator: " ").trimmingCharacters(in: .whitespaces)
                if key == "name" { name = text } else if key == "description" { summary = text }
                blockKey = nil
                block = []
            }
            for line in lines.dropFirst() {
                if line.trimmingCharacters(in: .whitespaces) == "---" {
                    finishBlock()
                    break
                }
                if blockKey != nil {
                    if line.hasPrefix(" ") || line.hasPrefix("\t") || line.trimmingCharacters(in: .whitespaces).isEmpty {
                        block.append(line.trimmingCharacters(in: .whitespaces))
                        continue
                    }
                    finishBlock()
                }
                let parts = line.split(separator: ":", maxSplits: 1, omittingEmptySubsequences: false)
                guard parts.count == 2 else { continue }
                let key = parts[0].trimmingCharacters(in: .whitespaces)
                guard key == "name" || key == "description" else { continue }
                var value = parts[1].trimmingCharacters(in: .whitespaces)
                if value == "|" || value == ">" || value == "|-" || value == ">-" {
                    blockKey = key
                    continue
                }
                if value.hasPrefix("\"") && value.hasSuffix("\"") && value.count > 1 {
                    value = String(value.dropFirst().dropLast())
                }
                if key == "name" { name = value }
                if key == "description" { summary = value }
            }
            finishBlock()
        }
        if summary.isEmpty {
            for line in lines {
                let trimmed = line.trimmingCharacters(in: .whitespaces)
                if trimmed.hasPrefix("#") {
                    if name == nil { name = trimmed.drop { $0 == "#" }.trimmingCharacters(in: .whitespaces) }
                    continue
                }
                if !trimmed.isEmpty && trimmed != "---" {
                    summary = trimmed
                    break
                }
            }
        }
        return (name, summary)
    }

    /// A prompt's text without its frontmatter, ready to submit to an agent.
    static func promptBody(_ text: String) -> String {
        var lines = text.components(separatedBy: "\n")
        if lines.first?.trimmingCharacters(in: .whitespaces) == "---",
           let end = lines.dropFirst().firstIndex(where: { $0.trimmingCharacters(in: .whitespaces) == "---" }) {
            lines = Array(lines[(end + 1)...])
        }
        return lines.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
    }

    // MARK: - Writing

    /// Creates or replaces a library item and returns it.
    @discardableResult
    static func save(kind: Kind, slug: String, text: String, hosts: [AgentHost], home: String = NSHomeDirectory()) throws -> Item {
        let directory = directory(kind, home: home)
        try FileManager.default.createDirectory(atPath: directory, withIntermediateDirectories: true)
        let path = kind == .skill ? "\(directory)/\(slug)" : "\(directory)/\(slug).md"
        if kind == .skill {
            try FileManager.default.createDirectory(atPath: path, withIntermediateDirectories: true)
        }
        let contentPath = kind == .skill ? "\(path)/SKILL.md" : path
        try text.write(toFile: contentPath, atomically: true, encoding: .utf8)
        return item(kind: kind, slug: slug, path: path, hosts: hosts)
    }

    static func delete(_ item: Item, hosts: [AgentHost]) throws {
        for host in hosts { try? uninstall(item, from: host) }
        try FileManager.default.removeItem(atPath: item.path)
    }

    // MARK: - Per-host installation

    static func destination(_ item: Item, in host: AgentHost) -> String {
        item.kind == .skill ? host.skillPath(item.slug) : host.promptPath(item.slug)
    }

    /// Installed means the host's path links back to this library item.
    static func isInstalled(_ item: Item, in host: AgentHost) -> Bool {
        let path = destination(item, in: host)
        let target = try? FileManager.default.destinationOfSymbolicLink(atPath: path)
        if let target {
            let resolved = target.hasPrefix("/")
                ? target
                : URL(fileURLWithPath: path).deletingLastPathComponent().appendingPathComponent(target).standardized.path
            return URL(fileURLWithPath: resolved).standardized.path == URL(fileURLWithPath: item.path).standardized.path
        }
        return false
    }

    /// Symlinks the library item into the host so edits apply everywhere.
    static func install(_ item: Item, into host: AgentHost) throws {
        let path = destination(item, in: host)
        let directory = URL(fileURLWithPath: path).deletingLastPathComponent().path
        try FileManager.default.createDirectory(atPath: directory, withIntermediateDirectories: true)
        if FileManager.default.fileExists(atPath: path) || isDanglingLink(path) {
            guard (try? FileManager.default.destinationOfSymbolicLink(atPath: path)) != nil else {
                throw LibraryError.occupied(path)
            }
            try FileManager.default.removeItem(atPath: path)
        }
        try FileManager.default.createSymbolicLink(atPath: path, withDestinationPath: item.path)
    }

    static func uninstall(_ item: Item, from host: AgentHost) throws {
        let path = destination(item, in: host)
        guard (try? FileManager.default.destinationOfSymbolicLink(atPath: path)) != nil else {
            // Never delete a real file the user put there by hand.
            if FileManager.default.fileExists(atPath: path) { throw LibraryError.occupied(path) }
            return
        }
        try FileManager.default.removeItem(atPath: path)
    }

    /// Adopts a skill or prompt that already lives in a host's own folder:
    /// moves it into the library and links it back.
    @discardableResult
    static func adopt(kind: Kind, slug: String, from host: AgentHost, hosts: [AgentHost], home: String = NSHomeDirectory()) throws -> Item {
        let source = kind == .skill ? host.skillPath(slug) : host.promptPath(slug)
        guard (try? FileManager.default.destinationOfSymbolicLink(atPath: source)) == nil else {
            throw LibraryError.alreadyLinked(source)
        }
        let directory = directory(kind, home: home)
        try FileManager.default.createDirectory(atPath: directory, withIntermediateDirectories: true)
        let path = kind == .skill ? "\(directory)/\(slug)" : "\(directory)/\(slug).md"
        guard !FileManager.default.fileExists(atPath: path) else { throw LibraryError.occupied(path) }
        try FileManager.default.moveItem(atPath: source, toPath: path)
        var adopted = item(kind: kind, slug: slug, path: path, hosts: hosts)
        try install(adopted, into: host)
        adopted.installedIn.insert(host.id)
        return adopted
    }

    /// Skills and prompts in a host's folder that aren't in the library yet.
    static func unmanaged(_ kind: Kind, in host: AgentHost) -> [String] {
        let directory = kind == .skill ? host.skillsDirectory : host.promptsDirectory
        let names = (try? FileManager.default.contentsOfDirectory(atPath: directory)) ?? []
        return names.compactMap { name in
            let path = "\(directory)/\(name)"
            guard (try? FileManager.default.destinationOfSymbolicLink(atPath: path)) == nil else { return nil }
            switch kind {
            case .skill:
                return FileManager.default.fileExists(atPath: "\(path)/SKILL.md") ? name : nil
            case .prompt:
                return name.hasSuffix(".md") ? String(name.dropLast(3)) : nil
            }
        }
        .sorted()
    }

    private static func isDanglingLink(_ path: String) -> Bool {
        (try? FileManager.default.destinationOfSymbolicLink(atPath: path)) != nil
    }

    enum LibraryError: LocalizedError {
        case occupied(String)
        case alreadyLinked(String)

        var errorDescription: String? {
            switch self {
            case .occupied(let path): "\(path) already exists and isn't managed by Octet"
            case .alreadyLinked(let path): "\(path) is already a link"
            }
        }
    }
}
