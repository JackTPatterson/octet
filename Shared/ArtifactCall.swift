import Foundation

/// A call to Claude Code's artifact tools: `Artifact` publishes an HTML page
/// as a private claude.ai page (or reads, lists, opens or deletes one), and
/// `ArtifactComments` / `ArtifactData` work with a published one. Without
/// this a publish reads as a bare "Artifact" row, with its link buried in
/// the result.
struct ArtifactCall: Equatable {
    enum Action: String {
        case publish, read, list, delete, open, pin, unpin, quickstart
        case comments, data
    }

    let action: Action
    /// The page's link: the one the call named, else the first in its result.
    var url: URL?
    /// The local page it publishes, for a preview in the browser.
    var filePath: String?
    var title: String?
    var detail: String?

    static let tools: Set<String> = ["Artifact", "ArtifactComments", "ArtifactData"]

    static func isArtifact(_ tool: String) -> Bool { tools.contains(tool) }

    init?(tool: String, input: [String: Any]?, result: String?) {
        guard Self.isArtifact(tool) else { return nil }
        let input = input ?? [:]
        switch tool {
        case "ArtifactComments": action = .comments
        case "ArtifactData": action = .data
        default: action = (input["action"] as? String).flatMap(Action.init(rawValue:)) ?? .publish
        }
        url = (input["url"] as? String).flatMap(Self.link) ?? result.flatMap(Self.firstLink)
        let path = (input["file_path"] as? String).flatMap { $0.isEmpty ? nil : $0 }
        filePath = path
        title = [input["title"] as? String, path.flatMap { Self.cachedTitle(atPath: $0) }, path.map { ($0 as NSString).lastPathComponent }]
            .compactMap { $0?.trimmingCharacters(in: .whitespacesAndNewlines) }
            .first { !$0.isEmpty }
        detail = (input["description"] as? String).flatMap { $0.isEmpty ? nil : $0 }
    }

    /// "Published", "Opened", … for the row, from what it did.
    var verb: String {
        switch action {
        case .publish: "Published"
        case .read: "Read"
        case .list: "Listed artifacts"
        case .delete: "Deleted"
        case .open: "Opened"
        case .pin: "Pinned"
        case .unpin: "Unpinned"
        case .quickstart: "Started an artifact"
        case .comments: "Comments"
        case .data: "Data"
        }
    }

    /// What the row says after the tool's name.
    var summary: String {
        let name = title ?? url.map { $0.lastPathComponent } ?? ""
        return name.isEmpty ? verb : "\(verb) \(name)"
    }

    /// A claude.ai artifact link: claude.ai/artifact/{id} or
    /// claude.ai/code/artifact/{uuid}.
    static let pattern = #"https://claude\.ai/(?:code/)?artifact/[A-Za-z0-9_-]+"#

    static func link(_ text: String) -> URL? {
        guard text.range(of: "^" + pattern + "$", options: .regularExpression) != nil else { return nil }
        return URL(string: text)
    }

    static func firstLink(in text: String) -> URL? {
        text.range(of: pattern, options: .regularExpression).flatMap { URL(string: String(text[$0])) }
    }

    /// The `<title>` of a local HTML page, read from its start.
    static func pageTitle(atPath path: String) -> String? {
        guard let handle = FileHandle(forReadingAtPath: path) else { return nil }
        defer { try? handle.close() }
        guard let data = try? handle.read(upToCount: 64 * 1024) else { return nil }
        return pageTitle(in: String(decoding: data, as: UTF8.self))
    }

    static func pageTitle(in html: String) -> String? {
        guard let range = html.range(of: #"<title[^>]*>([^<]*)</title>"#, options: [.regularExpression, .caseInsensitive]) else { return nil }
        let tag = String(html[range])
        guard let open = tag.firstIndex(of: ">"), let close = tag.range(of: "</", options: .backwards) else { return nil }
        let text = tag[tag.index(after: open)..<close.lowerBound]
            .replacingOccurrences(of: "&amp;", with: "&").replacingOccurrences(of: "&lt;", with: "<")
            .replacingOccurrences(of: "&gt;", with: ">").replacingOccurrences(of: "&quot;", with: "\"")
            .replacingOccurrences(of: "&#39;", with: "'")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return text.isEmpty ? nil : text
    }

    /// Titles already read, as a view asks on every redraw.
    private static var titles: [String: String?] = [:]
    private static let lock = NSLock()

    private static func cachedTitle(atPath path: String) -> String? {
        lock.lock()
        defer { lock.unlock() }
        if let known = titles[path] { return known }
        let title = pageTitle(atPath: path)
        titles[path] = title
        return title
    }
}

extension AgentToolCall {
    /// The artifact this call published or worked with, when it's one.
    var artifact: ArtifactCall? {
        guard ArtifactCall.isArtifact(name) else { return nil }
        return ArtifactCall(tool: name, input: inputObject, result: result)
    }
}
