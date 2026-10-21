import Foundation

/// Follows a JSON-lines log as an agent writes it, handing back only the
/// lines that are new and complete. The hub's transcripts poll with it, so
/// an idle session costs a stat and a growing one only its new bytes, where
/// they used to re-read and re-parse the whole log every two seconds.
struct TranscriptLineTail {
    enum Pull: Equatable {
        /// Nothing new since the last pull.
        case unchanged
        /// These lines follow everything handed back so far.
        case appended([String])
        /// The file was replaced or truncated: start over with these.
        case restarted([String])
    }

    /// How far into the file has been read.
    private(set) var offset: UInt64 = 0
    /// The first read began partway through a long file.
    private(set) var startedMidway = false
    private var partial = ""
    private var started = false
    private var identity: UInt64?

    init() {}

    /// Complete lines in `chunk`, carrying an unfinished last line over to
    /// the next chunk.
    mutating func lines(in chunk: String) -> [String] {
        let text = partial + chunk
        var lines = text.components(separatedBy: "\n")
        // Only a trailing newline means the last line is complete.
        partial = text.hasSuffix("\n") ? "" : (lines.popLast() ?? "")
        return lines.filter { !$0.isEmpty }
    }

    /// Reads what's new in `path`. The first pull takes at most the last
    /// `firstReadBytes`, from a line boundary. Safe off the main thread.
    mutating func pull(path: String, firstReadBytes: Int = 4 * 1024 * 1024) -> Pull {
        guard let handle = FileHandle(forReadingAtPath: path) else { return .unchanged }
        defer { try? handle.close() }
        let size = (try? handle.seekToEnd()) ?? 0
        let current = (try? FileManager.default.attributesOfItem(atPath: path))?[.systemFileNumber] as? UInt64
        var restarted = false
        if started, size < offset || (identity != nil && current != identity) {
            offset = 0
            partial = ""
            started = false
            restarted = true
        }
        identity = current
        if !started {
            started = true
            let length = min(size, UInt64(firstReadBytes))
            try? handle.seek(toOffset: size - length)
            var text = String(decoding: (try? handle.readToEnd()) ?? Data(), as: UTF8.self)
            startedMidway = length < size
            // A partial first line would parse as nothing; drop it.
            if startedMidway, let newline = text.firstIndex(of: "\n") {
                text = String(text[text.index(after: newline)...])
            }
            offset = size
            let found = lines(in: text)
            return restarted ? .restarted(found) : .appended(found)
        }
        guard size > offset else { return .unchanged }
        try? handle.seek(toOffset: offset)
        let data = (try? handle.readToEnd()) ?? Data()
        offset = size
        let found = lines(in: String(decoding: data, as: UTF8.self))
        return found.isEmpty ? .unchanged : .appended(found)
    }
}

extension AgentConversation {
    /// Folds more of a Claude Code log into the conversation so far, the
    /// way `replay(lines:)` reads a whole one: a tool's result finds the
    /// call it answers even when the call came in an earlier batch.
    mutating func replay(appending lines: [String]) {
        for line in lines {
            guard let data = line.data(using: .utf8),
                  let record = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
                  record["isMeta"] as? Bool != true, record["isSidechain"] as? Bool != true else { continue }
            let firstNewItem = items.count
            switch record["type"] as? String {
            case "assistant":
                apply(record)
            case "user":
                guard let message = record["message"] as? [String: Any] else { continue }
                if let text = Self.replayedUserText(message["content"]) {
                    let images = Self.images(in: message["content"])
                    let shown = images.isEmpty ? text : Self.strippingImageMarkers(text)
                    let id = record["uuid"] as? String ?? UUID().uuidString
                    noteUser(id)
                    items.append(AgentItem(id: id, kind: .user(shown), images: images))
                } else {
                    apply(record)
                }
            default:
                break
            }
            if let timestamp = record["timestamp"] as? String, let date = Self.replayedDate(timestamp) {
                for index in firstNewItem..<items.count { items[index].createdAt = date }
            }
            if sessionId == nil { sessionId = record["sessionId"] as? String }
            if cwd == nil { cwd = record["cwd"] as? String }
        }
        isRunning = false
    }

    private static func replayedDate(_ value: String) -> Date? {
        let fractional = ISO8601DateFormatter()
        fractional.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return fractional.date(from: value) ?? ISO8601DateFormatter().date(from: value)
    }

    /// A person's message, or nil for tool results and command echoes
    /// (as `replay(lines:)` reads them).
    private static func replayedUserText(_ content: Any?) -> String? {
        let text: String
        if let string = content as? String {
            text = string
        } else if let blocks = content as? [[String: Any]], !blocks.contains(where: { $0["type"] as? String == "tool_result" }) {
            text = blocks.compactMap { $0["type"] as? String == "text" ? $0["text"] as? String : nil }.joined(separator: "\n")
        } else {
            return nil
        }
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.hasPrefix("<command-"), !trimmed.hasPrefix("<local-command") else { return nil }
        guard !trimmed.isEmpty || !images(in: content).isEmpty else { return nil }
        return trimmed
    }
}
