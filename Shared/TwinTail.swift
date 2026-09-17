import Foundation

/// Follows a session file as the agent writes it: the first read takes the
/// tail of what is already there, and every read after it takes only the new
/// bytes. A long conversation is parsed once, not on every poll.
struct TwinTail {
    /// The agent whose format the file is in.
    let format: String?
    private(set) var conversation = TwinConversation()
    /// How far into the file has been read.
    private(set) var offset: UInt64 = 0
    /// A line the agent hadn't finished writing when the last read landed.
    private var partial = ""
    private(set) var started = false
    /// Which file the offset belongs to: a session that is replaced rather
    /// than appended to can land on the same length as the old one.
    private var identity: UInt64?

    init(format: String?) {
        self.format = format
    }

    /// Parses a chunk that follows everything consumed so far, and returns
    /// whether the conversation changed.
    @discardableResult
    mutating func consume(_ chunk: String, newOffset: UInt64) -> Bool {
        offset = newOffset
        guard !chunk.isEmpty else { return false }
        let text = partial + chunk
        // Only a trailing newline means the last line is complete.
        let endsClean = text.hasSuffix("\n")
        var lines = text.components(separatedBy: "\n")
        partial = endsClean ? "" : (lines.popLast() ?? "")
        let usable = lines.filter { !$0.isEmpty }
        guard !usable.isEmpty else { return false }
        let batch = TwinTranscript.parse(agent: format, lines: usable)
        let before = conversation
        conversation = TwinTranscript.merge(conversation, with: batch)
        started = true
        return conversation != before
    }

    /// The file was replaced or truncated: start again from nothing.
    mutating func rewind() {
        conversation = TwinConversation()
        offset = 0
        partial = ""
        started = false
        identity = nil
    }

    /// Reads whatever is new in `path`, or the tail of it on the first pass.
    /// Returns whether anything changed. Safe to call off the main thread.
    @discardableResult
    mutating func pull(path: String, firstReadBytes: Int = 2 * 1024 * 1024) -> Bool {
        guard let handle = FileHandle(forReadingAtPath: path) else { return false }
        defer { try? handle.close() }
        let size = (try? handle.seekToEnd()) ?? 0
        // Rotated or rewritten underneath us: a shorter file, or a different
        // file at the same path.
        let current = Self.identity(of: path)
        if size < offset || (identity != nil && current != identity) { rewind() }
        identity = current
        if !started, offset == 0 {
            let length = min(size, UInt64(firstReadBytes))
            try? handle.seek(toOffset: size - length)
            guard let data = try? handle.readToEnd() else { return false }
            var text = String(decoding: data, as: UTF8.self)
            // A partial first line would parse as nothing; drop it.
            if length < size, let newline = text.firstIndex(of: "\n") {
                text = String(text[text.index(after: newline)...])
            }
            return consume(text, newOffset: size)
        }
        guard size > offset else { return false }
        try? handle.seek(toOffset: offset)
        guard let data = try? handle.readToEnd() else { return false }
        return consume(String(decoding: data, as: UTF8.self), newOffset: size)
    }

    /// The file itself, rather than its name.
    private static func identity(of path: String) -> UInt64? {
        (try? FileManager.default.attributesOfItem(atPath: path))?[.systemFileNumber] as? UInt64
    }
}
