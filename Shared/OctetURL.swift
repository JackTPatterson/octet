import Foundation

/// `octet://` links, for scripts, Shortcuts, other apps and `octet-cli`:
///
///     octet://open?path=/Users/me/api                  a workspace on a folder
///     octet://run?agent=claude&path=/Users/me/api&prompt=Fix%20the%20tests
///                                                      an agent in a new tab there
///     octet://new?prompt=Fix%20the%20tests&dir=/Users/me/api&agent=codex
///                                                      a new conversation there, the
///                                                      prompt typed in but not sent
///     octet://send?text=npm%20test                     typed into the pane in front
///     octet://plugin?id=containers                     a registry plugin, installed
///     octet://plugin-settings?id=issues                that plugin's settings
enum OctetURL: Equatable {
    case open(path: String)
    case run(agent: String, path: String?, prompt: String?)
    /// A prompt link: a new conversation with `prompt` in its composer.
    case new(prompt: String, dir: String?, agent: String?)
    case send(text: String)
    case installPlugin(id: String)
    case pluginSettings(id: String)

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
        case "new":
            guard let raw = query["prompt"], let prompt = PromptLink.prompt(fromLink: raw) else { return nil }
            let agent = query["agent"].flatMap { $0.isEmpty ? nil : $0.lowercased() }
            if let agent, !agent.allSatisfy({ $0.isLetter || $0.isNumber || $0 == "-" || $0 == "_" }) { return nil }
            self = .new(prompt: prompt, dir: path(query["dir"]), agent: agent)
        case "send":
            guard let text = query["text"], !text.isEmpty else { return nil }
            self = .send(text: text)
        case "plugin":
            guard let id = query["id"],
                  id.range(of: "^[a-z0-9][a-z0-9._-]*$", options: .regularExpression) != nil else { return nil }
            self = .installPlugin(id: id)
        case "plugin-settings":
            guard let id = query["id"],
                  id.range(of: "^[a-z0-9][a-z0-9._-]*$", options: .regularExpression) != nil else { return nil }
            self = .pluginSettings(id: id)
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
        case .new(let prompt, let dir, let agent):
            components.host = "new"
            components.queryItems = [URLQueryItem(name: "prompt", value: prompt)]
                + (dir.map { [URLQueryItem(name: "dir", value: $0)] } ?? [])
                + (agent.map { [URLQueryItem(name: "agent", value: $0)] } ?? [])
            // Shared links get pasted where "+" reads as a space.
            components.percentEncodedQuery = components.percentEncodedQuery?.replacingOccurrences(of: "+", with: "%2B")
        case .send(let text):
            components.host = "send"
            components.queryItems = [URLQueryItem(name: "text", value: text)]
        case .installPlugin(let id):
            components.host = "plugin"
            components.queryItems = [URLQueryItem(name: "id", value: id)]
        case .pluginSettings(let id):
            components.host = "plugin-settings"
            components.queryItems = [URLQueryItem(name: "id", value: id)]
        }
        return components.url!
    }
}
