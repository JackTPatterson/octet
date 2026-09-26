import Foundation

/// `octet://` links, for scripts, Shortcuts, other apps and `octet-cli`:
///
///     octet://open?path=/Users/me/api                  a workspace on a folder
///     octet://run?agent=claude&path=/Users/me/api&prompt=Fix%20the%20tests
///                                                      an agent in a new tab there
///     octet://send?text=npm%20test                     typed into the pane in front
enum OctetURL: Equatable {
    case open(path: String)
    case run(agent: String, path: String?, prompt: String?)
    case send(text: String)

    static let scheme = "octet"

    init?(_ url: URL) {
        guard url.scheme?.lowercased() == Self.scheme,
              let components = URLComponents(url: url, resolvingAgainstBaseURL: false) else { return nil }
        let query = Dictionary((components.queryItems ?? []).compactMap { item in item.value.map { (item.name, $0) } },
                               uniquingKeysWith: { first, _ in first })
        func path(_ raw: String?) -> String? {
            guard let raw, !raw.isEmpty else { return nil }
            return (raw as NSString).expandingTildeInPath
        }
        switch components.host?.lowercased() {
        case "open":
            guard let folder = path(query["path"]) else { return nil }
            self = .open(path: folder)
        case "run":
            guard let agent = query["agent"], !agent.isEmpty,
                  agent.allSatisfy({ $0.isLetter || $0.isNumber || $0 == "-" || $0 == "_" }) else { return nil }
            self = .run(agent: agent, path: path(query["path"]), prompt: query["prompt"].flatMap { $0.isEmpty ? nil : $0 })
        case "send":
            guard let text = query["text"], !text.isEmpty else { return nil }
            self = .send(text: text)
        default:
            return nil
        }
    }

    var url: URL {
        var components = URLComponents()
        components.scheme = Self.scheme
        switch self {
        case .open(let path):
            components.host = "open"
            components.queryItems = [URLQueryItem(name: "path", value: path)]
        case .run(let agent, let path, let prompt):
            components.host = "run"
            components.queryItems = [URLQueryItem(name: "agent", value: agent)]
                + (path.map { [URLQueryItem(name: "path", value: $0)] } ?? [])
                + (prompt.map { [URLQueryItem(name: "prompt", value: $0)] } ?? [])
        case .send(let text):
            components.host = "send"
            components.queryItems = [URLQueryItem(name: "text", value: text)]
        }
        return components.url!
    }
}
