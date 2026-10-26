import Foundation

/// Where a file changed, worked out from its text before and after, for
/// showing an agent's edit as it lands: the region to retype, the lines to
/// light up and where the agent's cursor ends. All offsets are UTF-16, the
/// units a text view counts in.
struct LiveEdit: Equatable {
    /// What was replaced, in the old text, and what replaced it, in the new.
    var oldRange: NSRange
    var newRange: NSRange
    /// The changed lines in the new text, merged where they touch. A change
    /// that only removed text is a zero-length range where it was.
    var hunks: [NSRange]
    /// Where the agent's cursor rests: the end of what it last wrote.
    var cursor: Int

    private static let diffLineLimit = 3_000

    static func between(old: String, new: String) -> LiveEdit? {
        guard old != new else { return nil }
        let before = old as NSString
        let after = new as NSString
        let shortest = min(before.length, after.length)
        var prefix = 0
        while prefix < shortest, before.character(at: prefix) == after.character(at: prefix) { prefix += 1 }
        var suffix = 0
        while suffix < shortest - prefix,
              before.character(at: before.length - 1 - suffix) == after.character(at: after.length - 1 - suffix) { suffix += 1 }
        // Never cut a surrogate pair in half.
        if prefix > 0, UTF16.isLeadSurrogate(after.character(at: prefix - 1)) { prefix -= 1 }
        if suffix > 0, UTF16.isTrailSurrogate(after.character(at: after.length - suffix)) { suffix -= 1 }
        let oldRange = NSRange(location: prefix, length: before.length - prefix - suffix)
        let newRange = NSRange(location: prefix, length: after.length - prefix - suffix)
        let hunks = lineHunks(old: old, new: new, fallback: newRange)
        // One contiguous change ends exactly where its text ends; several
        // end at the last line touched.
        let cursor = hunks.count > 1 ? (hunks.last.map { NSMaxRange($0) } ?? NSMaxRange(newRange)) : NSMaxRange(newRange)
        return LiveEdit(oldRange: oldRange, newRange: newRange, hunks: hunks, cursor: min(cursor, after.length))
    }

    /// The new text's lines that the old text didn't have.
    private static func lineHunks(old: String, new: String, fallback: NSRange) -> [NSRange] {
        let oldLines = old.split(separator: "\n", omittingEmptySubsequences: false)
        let newLines = new.split(separator: "\n", omittingEmptySubsequences: false)
        guard oldLines.count <= diffLineLimit, newLines.count <= diffLineLimit else { return [fallback] }
        // Each new line's start, in UTF-16.
        var starts: [Int] = []
        starts.reserveCapacity(newLines.count + 1)
        var position = 0
        for line in newLines {
            starts.append(position)
            position += line.utf16.count + 1
        }
        starts.append(position)
        let difference = newLines.difference(from: oldLines)
        var inserted = Set<Int>()
        var removedAt: [Int] = []
        for change in difference {
            switch change {
            case .insert(let offset, _, _): inserted.insert(offset)
            case .remove(let offset, _, _): removedAt.append(offset)
            }
        }
        var hunks: [NSRange] = []
        var run: (start: Int, end: Int)?
        let lineCount = newLines.count
        let total = (new as NSString).length
        for index in 0..<lineCount where inserted.contains(index) {
            let lineEnd = min(starts[index] + newLines[index].utf16.count, total)
            if let current = run, current.end + 1 >= starts[index] {
                run = (current.start, lineEnd)
            } else {
                if let current = run { hunks.append(NSRange(location: current.start, length: current.end - current.start)) }
                run = (starts[index], lineEnd)
            }
        }
        if let current = run { hunks.append(NSRange(location: current.start, length: current.end - current.start)) }
        // A deletion with nothing added leaves its place to point at.
        if hunks.isEmpty, !removedAt.isEmpty {
            let place = min(starts[min(max(removedAt.min() ?? 0, 0), lineCount)], total)
            return [NSRange(location: place, length: 0)]
        }
        return hunks.isEmpty ? [fallback] : hunks
    }

    /// Where `snippet` starts in `text`, as a UTF-16 offset: where an Edit
    /// that hasn't run yet is about to change the file.
    static func location(of snippet: String, in text: String) -> Int? {
        guard !snippet.isEmpty else { return nil }
        let range = (text as NSString).range(of: snippet)
        return range.location == NSNotFound ? nil : range.location
    }
}
