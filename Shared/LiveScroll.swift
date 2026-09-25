import Foundation

/// A pane's scroll position as the session server reports it, in rows.
struct PaneScroll: Codable, Equatable {
    let offsetFromBottom: Int
    let maxOffsetFromBottom: Int
    let viewportRows: Int

    enum CodingKeys: String, CodingKey {
        case offsetFromBottom = "offset_from_bottom"
        case maxOffsetFromBottom = "max_offset_from_bottom"
        case viewportRows = "viewport_rows"
    }

    /// From a `pane.scroll_changed` event: the pane and where it is now.
    static func parseEvent(_ object: [String: Any]) -> (paneId: String, scroll: PaneScroll)? {
        guard object["event"] as? String == "pane.scroll_changed",
              let data = object["data"] as? [String: Any],
              let paneId = data["pane_id"] as? String,
              let raw = data["scroll"] as? [String: Any] else { return nil }
        func int(_ key: String) -> Int? { (raw[key] as? NSNumber)?.intValue }
        guard let offset = int("offset_from_bottom"), let max = int("max_offset_from_bottom") else { return nil }
        return (paneId, PaneScroll(offsetFromBottom: offset, maxOffsetFromBottom: max, viewportRows: int("viewport_rows") ?? 0))
    }
}

/// Counts what arrived below while someone reads back through a pane. The
/// session server keeps the view on the lines being read as output grows (the
/// offset from the bottom rises with it), so nothing is yanked away; what's
/// missing is knowing there's more below and a way back to it.
struct LiveScrollTracker: Equatable {
    /// Lines added below the view since it left the bottom.
    private(set) var newLines = 0
    private var last: PaneScroll?

    /// Whether the pane is showing its latest output.
    var isLive: Bool { (last?.offsetFromBottom ?? 0) == 0 }

    mutating func update(_ scroll: PaneScroll) {
        defer { last = scroll }
        guard scroll.offsetFromBottom > 0 else {
            newLines = 0
            return
        }
        // Leaving the bottom starts a fresh count.
        guard let last, last.offsetFromBottom > 0 else {
            newLines = 0
            return
        }
        newLines += max(0, scroll.maxOffsetFromBottom - last.maxOffsetFromBottom)
        // Scrolling down reads some of them; there can't be more unread lines
        // than rows below the view.
        newLines = min(newLines, scroll.offsetFromBottom)
    }

    /// What the pill says.
    var label: String {
        switch newLines {
        case 0: return "Jump to live"
        case 1: return "1 new line"
        default: return "\(newLines) new lines"
        }
    }
}
