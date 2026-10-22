import Foundation

/// A command a project keeps to hand, after T3 Code's project actions: a
/// name, the shell command it runs, and a mark for the menu.
struct ProjectAction: Codable, Identifiable, Equatable {
    var id: String
    var name: String
    var command: String
    /// An `OctetIcon` key from `ProjectActionIcon`.
    var icon: String = ProjectActionIcon.play.rawValue
}

/// The marks an action can wear.
enum ProjectActionIcon: String, CaseIterable {
    case play, terminal, hammer, flask, bolt, gearshape

    var title: String {
        switch self {
        case .play: "Play"
        case .terminal: "Terminal"
        case .hammer: "Build"
        case .flask: "Test"
        case .bolt: "Fast"
        case .gearshape: "Setup"
        }
    }
}

/// Each project's actions, by its root folder, kept across launches.
@MainActor
final class ProjectActionsStore: ObservableObject {
    static let shared = ProjectActionsStore()
    private static let key = "octet.projectActions"

    @Published private(set) var actions: [String: [ProjectAction]]
    @Published private(set) var repositoryActions: [String: [ProjectAction]] = [:]
    @Published private(set) var configurationErrors: [String: String] = [:]
    private let defaults: UserDefaults

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        actions = defaults.data(forKey: Self.key)
            .flatMap { try? JSONDecoder().decode([String: [ProjectAction]].self, from: $0) } ?? [:]
    }

    /// The folder actions are kept under: the project's main checkout, so a
    /// worktree shares its project's actions.
    static func root(of directory: String) -> String {
        AccountProfiles.projectRoot(of: directory) ?? directory
    }

    func refreshConfiguration(root: String, checkout: String? = nil) {
        let key = checkout ?? root
        let loaded: [ProjectAction]
        let failure: String?
        do {
            let config = try ProjectConfiguration.load(checkout: key, root: root)
            loaded = (config.actions ?? []).map {
                ProjectAction(id: $0.id, name: $0.name, command: $0.command, icon: $0.icon ?? "play")
            }
            failure = nil
        } catch {
            loaded = []
            failure = error.localizedDescription
        }
        // Every workspace switch reads this again; only a real change may
        // redraw the windows that watch it.
        if repositoryActions[key] != loaded { repositoryActions[key] = loaded }
        if configurationErrors[key] != failure { configurationErrors[key] = failure }
    }

    func actions(for root: String, checkout: String? = nil) -> [ProjectAction] {
        let local = actions[root] ?? []
        return (repositoryActions[checkout ?? root] ?? []).filter { shared in !local.contains { $0.id == shared.id } } + local
    }

    /// Adds `action`, or replaces the one with its id. A new action gets an
    /// id from its name that no other action in the project has.
    @discardableResult
    func save(_ action: ProjectAction, root: String, isNew: Bool) -> ProjectAction {
        var list = actions(for: root)
        var action = action
        if isNew {
            action.id = Self.uniqueId(for: action.name, among: list.map(\.id))
            list.append(action)
        } else if let index = list.firstIndex(where: { $0.id == action.id }) {
            list[index] = action
        } else {
            list.append(action)
        }
        set(list, root: root)
        return action
    }

    func delete(_ id: String, root: String) {
        set(actions(for: root).filter { $0.id != id }, root: root)
    }

    private func set(_ list: [ProjectAction], root: String) {
        actions[root] = list.isEmpty ? nil : list
        if let data = try? JSONEncoder().encode(actions) { defaults.set(data, forKey: Self.key) }
    }

    nonisolated static func slug(_ name: String) -> String {
        let cleaned = name.lowercased().map { $0.isLetter || $0.isNumber ? $0 : "-" }
        let joined = String(cleaned).split(separator: "-", omittingEmptySubsequences: true).joined(separator: "-")
        return joined.isEmpty ? "action" : String(joined.prefix(24))
    }

    nonisolated static func uniqueId(for name: String, among taken: [String]) -> String {
        let base = slug(name)
        guard taken.contains(base) else { return base }
        var n = 2
        while taken.contains("\(base)-\(n)") { n += 1 }
        return "\(base)-\(n)"
    }
}

/// Actions worth offering for a project that has none, read from the files
/// that already say how it's built.
enum ProjectActionSuggestions {
    static let limit = 8

    static func suggestions(in root: String) -> [ProjectAction] {
        let fm = FileManager.default
        func read(_ name: String) -> Data? { fm.contents(atPath: (root as NSString).appendingPathComponent(name)) }
        var found: [ProjectAction] = []
        if let data = read("package.json") {
            found += packageScripts(data, manager: packageManager(has: { fm.fileExists(atPath: (root as NSString).appendingPathComponent($0)) }))
        }
        if let data = read("Makefile") ?? read("makefile"), let text = String(data: data, encoding: .utf8) {
            found += makeTargets(text)
        }
        if read("Cargo.toml") != nil { found += cargo() }
        var seen = Set<String>()
        return found.filter { seen.insert($0.id).inserted }
    }

    /// The package manager the lockfile points at; npm without one.
    static func packageManager(has file: (String) -> Bool) -> String {
        if file("pnpm-lock.yaml") { return "pnpm" }
        if file("yarn.lock") { return "yarn" }
        if file("bun.lockb") || file("bun.lock") { return "bun" }
        return "npm"
    }

    /// One action per entry of package.json's `scripts`, the usual ones first.
    static func packageScripts(_ data: Data, manager: String) -> [ProjectAction] {
        guard let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let scripts = object["scripts"] as? [String: Any] else { return [] }
        let names = scripts.keys.filter { !isHook($0, in: scripts) }
        return ordered(names).prefix(limit).map { name in
            ProjectAction(id: ProjectActionsStore.slug(name), name: name, command: "\(manager) run \(name)", icon: icon(for: name))
        }
    }

    /// `prebuild` and `postinstall` run by themselves around another script.
    private static func isHook(_ name: String, in scripts: [String: Any]) -> Bool {
        for prefix in ["pre", "post"] where name.hasPrefix(prefix) && scripts[String(name.dropFirst(prefix.count))] != nil {
            return true
        }
        return false
    }

    /// The targets a Makefile defines: not pattern rules, not `.PHONY`-style
    /// specials, not variable assignments.
    static func makeTargets(_ text: String) -> [ProjectAction] {
        var names: [String] = []
        for line in text.split(separator: "\n", omittingEmptySubsequences: true) {
            guard let first = line.first, first.isLetter || first.isNumber || first == "_",
                  let colon = line.firstIndex(of: ":") else { continue }
            // `x := 1` and `x ::= 1` are assignments; `x::` is a double-colon rule.
            let after = line[line.index(after: colon)...]
            if after.hasPrefix("=") || after.hasPrefix(":=") { continue }
            let head = line[..<colon]
            for name in head.split(separator: " ") where name.allSatisfy({ $0.isLetter || $0.isNumber || "_-.".contains($0) }) {
                if !names.contains(String(name)) { names.append(String(name)) }
            }
        }
        return ordered(names).prefix(limit).map { name in
            ProjectAction(id: "make-" + ProjectActionsStore.slug(name), name: "make " + name, command: "make " + name, icon: icon(for: name))
        }
    }

    static func cargo() -> [ProjectAction] {
        [("build", "hammer"), ("test", "flask"), ("run", "play"), ("check", "bolt")].map { name, icon in
            ProjectAction(id: "cargo-" + name, name: "cargo " + name, command: "cargo " + name, icon: icon)
        }
    }

    private static let usual = ["dev", "start", "build", "test", "lint", "check", "typecheck", "format"]

    /// The usual names first, in their usual order; the rest alphabetically.
    private static func ordered(_ names: [String]) -> [String] {
        names.sorted { a, b in
            let ia = usual.firstIndex(of: a) ?? usual.count
            let ib = usual.firstIndex(of: b) ?? usual.count
            return ia != ib ? ia < ib : a < b
        }
    }

    static func icon(for name: String) -> String {
        switch name {
        case "build", "compile": ProjectActionIcon.hammer.rawValue
        case "test", "check", "lint", "typecheck": ProjectActionIcon.flask.rawValue
        case "install", "setup", "bootstrap": ProjectActionIcon.gearshape.rawValue
        default: ProjectActionIcon.play.rawValue
        }
    }
}
