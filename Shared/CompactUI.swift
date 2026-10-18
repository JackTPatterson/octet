import Foundation

/// Small formatting pieces shared by Octet's compact UI, after T3 Code's:
/// line counts that stay narrow and elapsed times that read at a glance.
enum CompactFormat {
    /// A count in at most four characters: 999, 1.2k, 12k, 3.4m.
    static func count(_ value: Int) -> String {
        let n = max(0, value)
        func short(_ scaled: Double, _ unit: String) -> String {
            let text = scaled < 10 ? String(format: "%.1f", scaled) : String(Int(scaled.rounded()))
            return (text.hasSuffix(".0") ? String(text.dropLast(2)) : text) + unit
        }
        if n < 1_000 { return String(n) }
        if n < 1_000_000 { return short(Double(n) / 1_000, "k") }
        if n < 1_000_000_000 { return short(Double(n) / 1_000_000, "m") }
        return short(Double(n) / 1_000_000_000, "b")
    }

    /// A running clock for something still working: 42s, 3m 07s, 1h 05m.
    /// The seconds keep their width, so a ticking label doesn't jiggle.
    static func elapsed(_ seconds: TimeInterval) -> String {
        let total = max(0, Int(seconds))
        let minutes = total / 60
        if minutes == 0 { return "\(total)s" }
        let hours = minutes / 60
        if hours == 0 { return "\(minutes)m " + String(format: "%02ds", total % 60) }
        return "\(hours)h " + String(format: "%02dm", minutes % 60)
    }
}

/// Prompts put aside to send later: what you were typing, with its images,
/// kept while you write something else and brought back with ⌘S's menu.
/// Each project keeps its own, newest first, up to `limit`, kept across
/// launches. Entries from before stashes were per project (no project) show
/// in every project until they're used.
struct PromptStash: Equatable {
    struct Entry: Codable, Equatable, Identifiable {
        var id = UUID()
        var text: String
        var createdAt = Date()
        /// Attached images, as the composer holds them (encoded, scaled).
        var images: [Data] = []
        /// The project folder it was stashed in; nil for older entries.
        var project: String?

        init(id: UUID = UUID(), text: String, createdAt: Date = Date(), images: [Data] = [], project: String? = nil) {
            self.id = id
            self.text = text
            self.createdAt = createdAt
            self.images = images
            self.project = project
        }

        init(from decoder: Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            id = try container.decodeIfPresent(UUID.self, forKey: .id) ?? UUID()
            text = try container.decodeIfPresent(String.self, forKey: .text) ?? ""
            createdAt = try container.decodeIfPresent(Date.self, forKey: .createdAt) ?? Date()
            images = try container.decodeIfPresent([Data].self, forKey: .images) ?? []
            project = try container.decodeIfPresent(String.self, forKey: .project)
        }

        /// The first line, for the menu.
        var title: String {
            let line = text.split(whereSeparator: \.isNewline).first.map(String.init) ?? text
            return line.trimmingCharacters(in: .whitespaces)
        }

        /// One line for the stash menu, as T3 Code shows it: the prompt with
        /// its whitespace run together, or what's attached when there's no
        /// text.
        var snippet: String {
            let flat = text.split(whereSeparator: \.isWhitespace).joined(separator: " ")
            if !flat.isEmpty { return flat.count > 90 ? String(flat.prefix(90)) + "…" : flat }
            guard !images.isEmpty else { return "(empty)" }
            return "(\(images.count) image\(images.count == 1 ? "" : "s"))"
        }

        fileprivate var key: String { text.trimmingCharacters(in: .whitespacesAndNewlines) }
    }

    /// Per project.
    static let limit = 20
    private(set) var entries: [Entry] = []

    init(entries: [Entry] = []) {
        self.entries = []
        for entry in entries.reversed() { insert(entry) }
    }

    /// The entries a project's composer offers: its own and the older,
    /// project-less ones, newest first.
    func entries(in project: String?) -> [Entry] {
        entries.filter { $0.project == nil || $0.project == project }
    }

    /// Puts a draft aside; nothing when there's neither text nor an image.
    /// The same draft again moves to the top rather than being kept twice.
    @discardableResult
    mutating func stash(_ text: String, images: [Data] = [], project: String? = nil, at date: Date = Date()) -> Entry? {
        let entry = Entry(text: text, createdAt: date, images: images, project: project)
        guard !entry.key.isEmpty || !images.isEmpty else { return nil }
        insert(entry)
        return entry
    }

    private mutating func insert(_ entry: Entry) {
        entries.removeAll { $0.project == entry.project && $0.key == entry.key && $0.images == entry.images }
        entries.insert(entry, at: 0)
        let mine = entries.indices.filter { entries[$0].project == entry.project }
        if mine.count > Self.limit {
            for index in mine.dropFirst(Self.limit).reversed() { entries.remove(at: index) }
        }
    }

    /// Takes an entry out, to put back in the composer. What the composer
    /// held is put aside in its place, so a swap loses nothing.
    mutating func take(_ id: UUID, replacing current: String = "", images: [Data] = [], project: String? = nil) -> Entry? {
        guard let index = entries.firstIndex(where: { $0.id == id }) else { return nil }
        let entry = entries.remove(at: index)
        stash(current, images: images, project: project)
        return entry
    }

    mutating func remove(_ id: UUID) { entries.removeAll { $0.id == id } }

    /// Empties a project's stash (and the older, shared entries it shows).
    mutating func clear(project: String?) { entries.removeAll { $0.project == nil || $0.project == project } }
    mutating func clear() { entries = [] }
}
