import Foundation

/// A list read from disk one entry at a time: an entry this build can't
/// read (a newer build's, or a damaged one) is skipped rather than costing
/// every other entry, and the file is copied aside first so a save that
/// follows can't lose what was skipped.
enum LossyList {
    static func decode<Element: Decodable>(_ type: Element.Type, from data: Data, file url: URL,
                                           decoder: JSONDecoder) -> [Element] {
        guard let entries = try? decoder.decode([Entry<Element>].self, from: data) else {
            keepAside(url)
            return []
        }
        let read = entries.compactMap(\.value)
        if read.count != entries.count { keepAside(url) }
        return read
    }

    /// `sleeping-workspaces.json` → `sleeping-workspaces.unreadable-<time>.json`.
    static func keepAside(_ url: URL) {
        let stamp = Int(Date().timeIntervalSince1970)
        let name = url.deletingPathExtension().lastPathComponent + ".unreadable-\(stamp)." + url.pathExtension
        try? FileManager.default.copyItem(at: url, to: url.deletingLastPathComponent().appendingPathComponent(name))
    }

    private struct Entry<Value: Decodable>: Decodable {
        let value: Value?
        init(from decoder: Decoder) throws { value = try? Value(from: decoder) }
    }
}
