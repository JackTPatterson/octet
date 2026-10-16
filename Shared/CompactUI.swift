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

/// Prompts put aside to send later: what you were typing, kept while you
/// write something else, and brought back into any conversation. The
/// newest first, up to `limit`, kept across launches.
struct PromptStash: Equatable {
    struct Entry: Codable, Equatable, Identifiable {
        var id = UUID()
        var text: String
        var createdAt = Date()

        /// The first line, for the menu.
        var title: String {
            let line = text.split(whereSeparator: \.isNewline).first.map(String.init) ?? text
            return line.trimmingCharacters(in: .whitespaces)
        }
    }

    static let limit = 20
    private(set) var entries: [Entry] = []

    init(entries: [Entry] = []) { self.entries = Array(entries.prefix(Self.limit)) }

    /// Puts `text` aside; nothing for blank text. The same text again moves
    /// to the top rather than being kept twice.
    @discardableResult
    mutating func stash(_ text: String, at date: Date = Date()) -> Entry? {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        entries.removeAll { $0.text.trimmingCharacters(in: .whitespacesAndNewlines) == trimmed }
        let entry = Entry(text: text, createdAt: date)
        entries.insert(entry, at: 0)
        if entries.count > Self.limit { entries.removeLast(entries.count - Self.limit) }
        return entry
    }

    /// Takes an entry out, to put back in the composer. What the composer
    /// held is put aside in its place, so a swap loses nothing.
    mutating func take(_ id: UUID, replacing current: String = "") -> Entry? {
        guard let index = entries.firstIndex(where: { $0.id == id }) else { return nil }
        let entry = entries.remove(at: index)
        stash(current)
        return entry
    }

    mutating func remove(_ id: UUID) { entries.removeAll { $0.id == id } }
    mutating func clear() { entries = [] }
}
