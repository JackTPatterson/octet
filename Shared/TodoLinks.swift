import CryptoKit
import Foundation

/// The personal todo list: the same markdown as `TODO.md`, kept in this
/// checkout's git directory (beside `octet-issue.json`), so it's never
/// committed, each worktree has its own, and an agent can still read it at
/// the path the prompt gives.
enum PersonalTodos {
    static let fileName = "octet-todos.md"
    static let linksName = "octet-todos.links.json"

    /// Where the list is for `directory`: the git-path file in a
    /// repository, else a file of its own under `fallback`.
    static func path(in directory: String, fallback: URL,
                     gitPath: (String, String) -> String? = PersonalTodos.gitPath) -> String {
        if let path = gitPath(fileName, directory), !path.isEmpty { return path }
        let digest = Insecure.SHA1.hash(data: Data(directory.utf8)).map { String(format: "%02x", $0) }.joined()
        return fallback.appendingPathComponent("todos").appendingPathComponent(digest + ".md").path
    }

    /// The links file beside the list at `path`.
    static func linksPath(besideList path: String) -> String {
        (path as NSString).deletingLastPathComponent + "/" + linksName
    }

    static func gitPath(_ name: String, in directory: String) -> String? {
        try? Git().run(["rev-parse", "--path-format=absolute", "--git-path", name], in: directory)
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }
}

/// What a todo is tied to, kept beside the personal list rather than in the
/// markdown, so the file stays plain: the agent it was sent to and the issue
/// it's linked to. Keyed by the item's content id. (A wait set on an item
/// is found by its title in the waits themselves.)
struct TodoLink: Codable, Equatable {
    /// The agent it went to: its brand id (claude, codex) and its name.
    var agent: String?
    var agentName: String?
    /// The Octet conversation it went to, when it went to one.
    var conversationId: String?
    /// "CLX-12", and where it opens.
    var issueKey: String?
    var issueURL: URL?

    var isEmpty: Bool { agent == nil && conversationId == nil && issueKey == nil }
}

struct TodoLinks: Codable, Equatable {
    var links: [String: TodoLink] = [:]

    subscript(id: String) -> TodoLink? {
        get { links[id] }
        set { links[id] = newValue?.isEmpty == true ? nil : newValue }
    }

    /// An item reworded or moved between lists keeps what it was tied to.
    mutating func rename(_ id: String, to newId: String) {
        guard id != newId, let link = links.removeValue(forKey: id) else { return }
        links[newId] = link
    }

    /// Drops links for items no longer in any list, so the file doesn't
    /// grow forever.
    func pruned(keeping ids: Set<String>) -> TodoLinks {
        TodoLinks(links: links.filter { ids.contains($0.key) })
    }

    static func load(from path: String) -> TodoLinks {
        guard let data = FileManager.default.contents(atPath: path),
              let links = try? JSONDecoder().decode(TodoLinks.self, from: data) else { return TodoLinks() }
        return links
    }

    func save(to path: String) throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .prettyPrinted]
        try FileManager.default.createDirectory(atPath: (path as NSString).deletingLastPathComponent,
                                                withIntermediateDirectories: true)
        try encoder.encode(self).write(to: URL(fileURLWithPath: path), options: .atomic)
    }
}
