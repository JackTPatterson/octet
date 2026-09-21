import Foundation

/// Plugins and MCP servers as Octet shows them, parsed from the agent CLIs.
/// Claude and Codex print the same shapes, so one parser serves both.
struct MarketplaceEntry: Identifiable, Equatable {
    enum Kind: String { case plugin, mcp }

    let kind: Kind
    /// `name@marketplace` for plugins, the server name for MCP.
    let identifier: String
    let name: String
    var summary: String = ""
    var marketplace: String = ""
    var version: String = ""
    var installCount: Int?
    /// Host ids where this is installed, and where it is enabled.
    var installedIn: Set<String> = []
    var enabledIn: Set<String> = []
    /// Per-host connection state for MCP servers ("Connected", "Failed…").
    var status: [String: String] = [:]
    /// stdio command or URL for MCP servers.
    var detail: String = ""

    var id: String { "\(kind.rawValue):\(identifier)" }
    var isInstalled: Bool { !installedIn.isEmpty }
}

enum MarketplaceCatalog {
    // MARK: Plugins

    /// Parses `<cli> plugin list --json [--available]` for one host and tags
    /// every entry with that host id.
    static func plugins(json data: Data, hostId: String) -> [MarketplaceEntry] {
        guard let object = try? JSONSerialization.jsonObject(with: data) else { return [] }
        let installed: [[String: Any]]
        let available: [[String: Any]]
        if let list = object as? [[String: Any]] {
            installed = list
            available = []
        } else if let dictionary = object as? [String: Any] {
            installed = dictionary["installed"] as? [[String: Any]] ?? []
            available = dictionary["available"] as? [[String: Any]] ?? []
        } else {
            return []
        }

        var entries: [String: MarketplaceEntry] = [:]
        for raw in installed + available {
            guard let identifier = (raw["pluginId"] ?? raw["id"]) as? String else { continue }
            let name = raw["name"] as? String ?? String(identifier.split(separator: "@").first ?? "")
            var entry = entries[identifier] ?? MarketplaceEntry(kind: .plugin, identifier: identifier, name: name)
            if let summary = raw["description"] as? String, !summary.isEmpty { entry.summary = summary }
            if let marketplace = raw["marketplaceName"] as? String {
                entry.marketplace = marketplace
            } else if entry.marketplace.isEmpty, let suffix = identifier.split(separator: "@").dropFirst().first {
                entry.marketplace = String(suffix)
            }
            if let version = raw["version"] as? String { entry.version = version }
            if let count = raw["installCount"] as? Int { entry.installCount = count }
            // Only the `installed` array carries install state.
            let isInstalled = raw["installedAt"] != nil || raw["installPath"] != nil || raw["installed"] as? Bool == true
            if isInstalled {
                entry.installedIn.insert(hostId)
                if raw["enabled"] as? Bool != false { entry.enabledIn.insert(hostId) }
            }
            entries[identifier] = entry
        }
        return Array(entries.values)
    }

    /// Merges per-host entries into one cross-agent list.
    static func merge(_ lists: [[MarketplaceEntry]]) -> [MarketplaceEntry] {
        var merged: [String: MarketplaceEntry] = [:]
        for entry in lists.flatMap({ $0 }) {
            guard var existing = merged[entry.id] else {
                merged[entry.id] = entry
                continue
            }
            existing.installedIn.formUnion(entry.installedIn)
            existing.enabledIn.formUnion(entry.enabledIn)
            existing.status.merge(entry.status) { _, new in new }
            if existing.summary.isEmpty { existing.summary = entry.summary }
            if existing.version.isEmpty { existing.version = entry.version }
            if existing.detail.isEmpty { existing.detail = entry.detail }
            if existing.installCount == nil { existing.installCount = entry.installCount }
            merged[entry.id] = existing
        }
        return Array(merged.values)
    }

    /// Ranks a browsing list: installed first, then popularity, then name.
    static func sorted(_ entries: [MarketplaceEntry]) -> [MarketplaceEntry] {
        entries.sorted { first, second in
            if first.isInstalled != second.isInstalled { return first.isInstalled }
            if (first.installCount ?? -1) != (second.installCount ?? -1) {
                return (first.installCount ?? -1) > (second.installCount ?? -1)
            }
            return first.name.localizedCaseInsensitiveCompare(second.name) == .orderedAscending
        }
    }

    // MARK: MCP servers

    /// Parses `claude mcp list` output:
    /// `name: <command or url> - ✔ Connected`.
    static func claudeMCP(_ output: String) -> [MarketplaceEntry] {
        output.components(separatedBy: "\n").compactMap { line in
            let text = line.trimmingCharacters(in: .whitespaces)
            guard let colon = text.firstIndex(of: ":"), !text.hasPrefix("Checking"), !text.isEmpty else { return nil }
            let name = String(text[..<colon]).trimmingCharacters(in: .whitespaces)
            guard !name.isEmpty, !name.contains(" MCP ") else { return nil }
            var rest = String(text[text.index(after: colon)...]).trimmingCharacters(in: .whitespaces)
            var status = ""
            if let separator = rest.range(of: " - ", options: .backwards) {
                status = String(rest[separator.upperBound...]).trimmingCharacters(in: .whitespaces)
                rest = String(rest[..<separator.lowerBound]).trimmingCharacters(in: .whitespaces)
            }
            var entry = MarketplaceEntry(kind: .mcp, identifier: name, name: name)
            entry.detail = rest
            entry.installedIn = ["claude"]
            entry.enabledIn = ["claude"]
            entry.status = status.isEmpty ? [:] : ["claude": status]
            return entry
        }
    }

    /// Parses `codex mcp list`, which prints one space-padded table for
    /// stdio servers and another for URL servers.
    static func codexMCP(_ output: String) -> [MarketplaceEntry] {
        var entries: [MarketplaceEntry] = []
        var columns: [(name: String, start: Int)] = []
        for line in output.components(separatedBy: "\n") {
            guard !line.trimmingCharacters(in: .whitespaces).isEmpty else {
                columns = []
                continue
            }
            if line.hasPrefix("Name") {
                columns = headerColumns(line)
                continue
            }
            guard !columns.isEmpty else { continue }
            let characters = Array(line)
            func field(_ title: String) -> String {
                guard let index = columns.firstIndex(where: { $0.name == title }), columns[index].start < characters.count else { return "" }
                let start = columns[index].start
                let end = index + 1 < columns.count ? min(columns[index + 1].start, characters.count) : characters.count
                return String(characters[start..<end]).trimmingCharacters(in: .whitespaces)
            }
            let name = field("Name")
            guard !name.isEmpty, name != "-" else { continue }
            var entry = MarketplaceEntry(kind: .mcp, identifier: name, name: name)
            let command = [field("Command"), field("Args")].filter { !$0.isEmpty && $0 != "-" }.joined(separator: " ")
            entry.detail = command.isEmpty ? field("Url") : command
            entry.installedIn = ["codex"]
            let status = field("Status")
            if status != "disabled" { entry.enabledIn = ["codex"] }
            if !status.isEmpty { entry.status = ["codex": status] }
            entries.append(entry)
        }
        return entries
    }

    /// Column titles and where each starts in a space-padded table header.
    private static func headerColumns(_ header: String) -> [(name: String, start: Int)] {
        var columns: [(String, Int)] = []
        var current = ""
        var start = 0
        var spaces = 0
        for (offset, character) in header.enumerated() {
            if character == " " {
                spaces += 1
                // Two spaces end a column; single spaces are part of a title.
                if spaces == 2 && !current.isEmpty {
                    columns.append((current.trimmingCharacters(in: .whitespaces), start))
                    current = ""
                }
                if !current.isEmpty { current.append(character) }
            } else {
                if current.isEmpty { start = offset }
                spaces = 0
                current.append(character)
            }
        }
        if !current.isEmpty { columns.append((current.trimmingCharacters(in: .whitespaces), start)) }
        return columns
    }

    /// Parses `<cli> plugin marketplace list` text into (name, source) pairs.
    static func marketplaces(_ output: String) -> [(name: String, source: String)] {
        var result: [(String, String)] = []
        var pending: String?
        for line in output.components(separatedBy: "\n") {
            let text = line.trimmingCharacters(in: .whitespaces)
            if text.hasPrefix("Source:") {
                let source = text.dropFirst("Source:".count).trimmingCharacters(in: .whitespaces)
                if let name = pending { result.append((name, source)) }
                pending = nil
            } else if text.hasPrefix("❯") {
                pending = text.dropFirst().trimmingCharacters(in: .whitespaces)
            } else if let name = pending, text.isEmpty {
                result.append((name, ""))
                pending = nil
            }
        }
        if let name = pending { result.append((name, "")) }
        return result
    }
}
