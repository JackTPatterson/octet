import Foundation

/// The commands you have run, for the inline suggestion at a prompt. Reads
/// whichever shell's history file exists, so it isn't tied to one shell.
struct CommandHistory {
    struct Entry: Equatable {
        let command: String
        /// Newer entries win ties; nil when the file records no times.
        let at: Date?
        var count: Int = 1
    }

    private(set) var entries: [Entry] = []
    /// command → index in `entries`, for counting repeats cheaply.
    private var seen: [String: Int] = [:]

    init(commands: [Entry] = []) {
        for entry in commands { add(entry) }
    }

    mutating func add(_ entry: Entry) {
        let command = entry.command.trimmingCharacters(in: .whitespaces)
        guard !command.isEmpty else { return }
        if let index = seen[command] {
            entries[index].count += 1
            // Keep the most recent timestamp.
            if let at = entry.at, entries[index].at.map({ at > $0 }) ?? true {
                entries[index] = Entry(command: command, at: at, count: entries[index].count)
            }
        } else {
            seen[command] = entries.count
            entries.append(Entry(command: command, at: entry.at, count: entry.count))
        }
    }

    /// The best completion for what has been typed: the most useful command
    /// that starts with `prefix`, or nil when nothing fits.
    func suggestion(for prefix: String) -> String? {
        let prefix = String(prefix.drop(while: { $0 == " " }))
        guard prefix.count >= 2 else { return nil }
        return ranked(matching: prefix).first
    }

    /// All matches, best first: recent beats old, repeated beats one-off.
    func ranked(matching prefix: String, limit: Int = 10) -> [String] {
        guard !prefix.isEmpty else { return [] }
        let now = Date()
        let matches: [Entry] = entries.filter { $0.command.hasPrefix(prefix) && $0.command != prefix }
        // Frecency: repeats matter, but a command from this hour matters
        // more than one from last month.
        var scored: [(command: String, score: Double)] = []
        scored.reserveCapacity(matches.count)
        for entry in matches {
            let age: TimeInterval = entry.at.map { max(now.timeIntervalSince($0), 0) } ?? (30 * 86_400)
            let recency: Double = 1 / (1 + age / 86_400)
            scored.append((entry.command, Double(entry.count) + recency * 8))
        }
        scored.sort { first, second in
            first.score == second.score ? first.command.count < second.command.count : first.score > second.score
        }
        return scored.prefix(limit).map(\.command)
    }

    // MARK: - Reading shells' own files

    /// History files Octet knows how to read, newest-relevant first.
    static func historyPaths(home: String = NSHomeDirectory(), environment: [String: String] = ProcessInfo.processInfo.environment) -> [String] {
        var paths: [String] = []
        if let histfile = environment["HISTFILE"], !histfile.isEmpty { paths.append(histfile) }
        paths += [
            "\(home)/.zsh_history",
            "\(home)/.bash_history",
            "\(home)/.local/share/fish/fish_history",
        ]
        return paths.filter { FileManager.default.fileExists(atPath: $0) }
    }

    /// Loads the most recent `limit` commands from whichever files exist.
    static func load(limit: Int = 4_000, home: String = NSHomeDirectory()) -> CommandHistory {
        var history = CommandHistory()
        for path in historyPaths(home: home) {
            guard let text = readTail(path) else { continue }
            for entry in parse(text, fish: path.hasSuffix("fish_history")).suffix(limit) {
                history.add(entry)
            }
        }
        return history
    }

    /// Parses zsh's extended format (`: <epoch>:<elapsed>;command`), plain
    /// lines, or fish's YAML-ish log.
    static func parse(_ text: String, fish: Bool = false) -> [Entry] {
        var entries: [Entry] = []
        var pendingCommand: String?
        var pendingDate: Date?
        for rawLine in text.components(separatedBy: "\n") {
            if fish {
                let line = rawLine.trimmingCharacters(in: .whitespaces)
                if line.hasPrefix("- cmd: ") {
                    if let command = pendingCommand { entries.append(Entry(command: command, at: pendingDate)) }
                    pendingCommand = String(line.dropFirst("- cmd: ".count))
                    pendingDate = nil
                } else if line.hasPrefix("when: "), let seconds = TimeInterval(line.dropFirst("when: ".count)) {
                    pendingDate = Date(timeIntervalSince1970: seconds)
                }
                continue
            }
            guard !rawLine.isEmpty else { continue }
            if rawLine.hasPrefix(": "), let semicolon = rawLine.firstIndex(of: ";") {
                let meta = rawLine[rawLine.index(rawLine.startIndex, offsetBy: 2)..<semicolon]
                let seconds = meta.split(separator: ":").first.flatMap { TimeInterval($0) }
                let command = String(rawLine[rawLine.index(after: semicolon)...])
                entries.append(Entry(command: command, at: seconds.map(Date.init(timeIntervalSince1970:))))
            } else {
                entries.append(Entry(command: rawLine, at: nil))
            }
        }
        if let command = pendingCommand { entries.append(Entry(command: command, at: pendingDate)) }
        return entries
    }

    /// History files grow without bound; only the tail is worth reading.
    private static func readTail(_ path: String, bytes: Int = 512 * 1024) -> String? {
        guard let handle = FileHandle(forReadingAtPath: path) else { return nil }
        defer { try? handle.close() }
        let size = (try? handle.seekToEnd()) ?? 0
        let length = min(size, UInt64(bytes))
        try? handle.seek(toOffset: size - length)
        guard let data = try? handle.readToEnd() else { return nil }
        return String(decoding: data, as: UTF8.self)
    }
}
