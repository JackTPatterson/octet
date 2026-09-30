import Foundation

/// Octet's plugin registry: an index of plugins anyone can publish, the way
/// Obsidian's community list or Zed's extensions repository work. The index
/// names each plugin's files and their SHA-256, and where on GitHub they
/// live; Octet downloads exactly those files and checks each one.
struct PluginRegistry: Codable, Equatable {
    static let formatVersion = 1
    /// The official index, in JackTPatterson/octet-plugins. A plugin's own
    /// files may live in any public GitHub repository the entry names.
    static let defaultURL = URL(string: "https://raw.githubusercontent.com/JackTPatterson/octet-plugins/main/registry.json")!

    var version: Int = formatVersion
    var plugins: [Entry] = []

    struct Entry: Codable, Equatable, Identifiable {
        let id: String
        let name: String
        var description: String = ""
        var author: String = ""
        var version: String = "0.0.0"
        var keywords: [String] = []
        /// `owner/name` of the GitHub repository holding the plugin.
        let repo: String
        /// A branch, tag or commit.
        var ref: String = "main"
        /// The plugin's folder in the repository; empty for its root.
        var path: String = ""
        var homepage: String?
        /// Where it runs; the Marketplace lists only what runs here.
        var platforms: [PluginPlatform] = PluginPlatform.unixDefault
        let files: [File]

        struct File: Codable, Equatable {
            let path: String
            let sha256: String
        }

        init(id: String, name: String, description: String = "", author: String = "", version: String = "0.0.0",
             keywords: [String] = [], repo: String, ref: String = "main", path: String = "",
             homepage: String? = nil, platforms: [PluginPlatform] = PluginPlatform.unixDefault, files: [File]) {
            self.id = id
            self.name = name
            self.description = description
            self.author = author
            self.version = version
            self.keywords = keywords
            self.repo = repo
            self.ref = ref
            self.path = path
            self.homepage = homepage
            self.platforms = platforms
            self.files = files
        }

        init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            id = try c.decode(String.self, forKey: .id)
            name = try c.decode(String.self, forKey: .name)
            description = try c.decodeIfPresent(String.self, forKey: .description) ?? ""
            author = try c.decodeIfPresent(String.self, forKey: .author) ?? ""
            version = try c.decodeIfPresent(String.self, forKey: .version) ?? "0.0.0"
            keywords = try c.decodeIfPresent([String].self, forKey: .keywords) ?? []
            repo = try c.decode(String.self, forKey: .repo)
            ref = try c.decodeIfPresent(String.self, forKey: .ref) ?? "main"
            path = try c.decodeIfPresent(String.self, forKey: .path) ?? ""
            homepage = try c.decodeIfPresent(String.self, forKey: .homepage)
            // Unknown platforms (a newer registry's) are skipped, not fatal.
            platforms = (try c.decodeIfPresent([String].self, forKey: .platforms))?
                .compactMap(PluginPlatform.init(rawValue:)) ?? PluginPlatform.unixDefault
            files = try c.decode([File].self, forKey: .files)
        }

        var runsHere: Bool { platforms.contains(.current) }

        /// Where one of its files downloads from.
        func url(of file: File) -> URL? {
            let folder = path.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
            let full = (folder.isEmpty ? "" : folder + "/") + file.path
            let encoded = full.split(separator: "/").map {
                String($0).addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? String($0)
            }.joined(separator: "/")
            return URL(string: "https://raw.githubusercontent.com/\(repo)/\(ref)/\(encoded)")
        }

        /// Why the entry can't be installed, or nil when it can.
        var problem: String? {
            if id.range(of: "^[a-z0-9][a-z0-9._-]*$", options: .regularExpression) == nil { return "a bad id" }
            if repo.range(of: "^[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+$", options: .regularExpression) == nil { return "a bad repository" }
            if !files.contains(where: { $0.path == OctetPluginManifest.fileName }) { return "no \(OctetPluginManifest.fileName)" }
            for file in files {
                if !Self.isSafe(file.path) { return "an unsafe file path: \(file.path)" }
                if file.sha256.range(of: "^[0-9a-f]{64}$", options: .regularExpression) == nil { return "a bad checksum for \(file.path)" }
            }
            return nil
        }

        /// A relative path that stays inside the plugin's folder.
        static func isSafe(_ path: String) -> Bool {
            guard !path.isEmpty, !path.hasPrefix("/"), !path.hasPrefix("~"), !path.contains("\\") else { return false }
            return !path.split(separator: "/", omittingEmptySubsequences: false).contains { $0 == ".." || $0 == "." || $0.isEmpty }
        }
    }

    static func parse(_ data: Data) throws -> PluginRegistry {
        let registry = try JSONDecoder().decode(PluginRegistry.self, from: data)
        guard registry.version <= formatVersion else {
            throw NSError(domain: "PluginRegistry", code: 1,
                          userInfo: [NSLocalizedDescriptionKey: "The plugin registry needs a newer Octet"])
        }
        return registry
    }

    /// Entries matching `query`, best first: a match in the name beats one
    /// in keywords, which beats the description. Empty returns them all.
    static func search(_ entries: [Entry], query: String) -> [Entry] {
        let words = query.lowercased().split(whereSeparator: \.isWhitespace).map(String.init)
        guard !words.isEmpty else { return entries.sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending } }
        let scored = entries.compactMap { entry -> (Entry, Int)? in
            let name = entry.name.lowercased(), id = entry.id.lowercased()
            let keywords = entry.keywords.map { $0.lowercased() }
            let rest = (entry.description + " " + entry.author).lowercased()
            var score = 0
            for word in words {
                if name.hasPrefix(word) || id.hasPrefix(word) { score += 8 }
                else if name.contains(word) || id.contains(word) { score += 5 }
                else if keywords.contains(where: { $0.hasPrefix(word) }) { score += 3 }
                else if rest.contains(word) { score += 1 }
                else { return nil }
            }
            return (entry, score)
        }
        return scored.sorted { $0.1 != $1.1 ? $0.1 > $1.1 : $0.0.name < $1.0.name }.map(\.0)
    }

    /// Whether `candidate` is a newer version than `installed`: dotted
    /// numbers compared piece by piece, anything else as text.
    static func isNewer(_ candidate: String, than installed: String) -> Bool {
        let a = candidate.split(separator: ".").map { Int($0) }
        let b = installed.split(separator: ".").map { Int($0) }
        guard !a.contains(nil), !b.contains(nil) else { return candidate != installed && candidate > installed }
        for index in 0..<max(a.count, b.count) {
            let x = index < a.count ? a[index]! : 0
            let y = index < b.count ? b[index]! : 0
            if x != y { return x > y }
        }
        return false
    }
}

/// Written beside a plugin installed from the registry: where it came from,
/// so Octet can offer updates and knows it may remove it.
struct PluginInstallReceipt: Codable, Equatable {
    static let fileName = ".octet-install.json"
    let id: String
    let version: String
    let repo: String
    let ref: String
    let registry: String
    let installedAt: Date

    static var encoder: JSONEncoder {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        return encoder
    }

    static var decoder: JSONDecoder {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return decoder
    }
}
