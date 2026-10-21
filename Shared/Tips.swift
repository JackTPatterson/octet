import Foundation

/// A short piece of Octet that is easy to miss. Tips surface one at a time in
/// the sidebar, and only when they apply to what is on screen.
struct Tip: Identifiable, Equatable {
    let id: String
    let title: String
    /// May name shortcuts as `{id}` (an `OctetShortcut` id), filled in with
    /// the keys as they're bound now: see `text(keys:)`.
    let body: String
    /// The shortcut id whose keys show beside the title; empty for none.
    var shortcut: String = ""
    /// Only shown when this holds for the current session.
    var applies: (TipContext) -> Bool = { _ in true }

    static func == (lhs: Tip, rhs: Tip) -> Bool { lhs.id == rhs.id }

    /// The body with each `{id}` replaced by `keys(id)`, or by "its
    /// shortcut" for one that's unassigned, so the sentence still reads.
    func text(keys: (String) -> String?) -> String {
        var result = ""
        var rest = Substring(body)
        while let open = rest.firstIndex(of: "{"), let close = rest[open...].firstIndex(of: "}") {
            result += rest[..<open]
            let id = String(rest[rest.index(after: open)..<close])
            result += keys(id) ?? "its shortcut"
            rest = rest[rest.index(after: close)...]
        }
        return result + rest
    }
}

/// What the session looks like right now, for deciding which tips fit.
struct TipContext: Equatable {
    var workspaceCount = 0
    var tabCount = 0
    var agentCount = 0
    var idleCount = 0
    var hasRecoverableSessions = false
    var hasUnnamedTabs = false
    var hasWorktree = false
    var hasPlugins = false
}

enum Tips {
    static let all: [Tip] = [
        Tip(id: "palette", title: "Everything from one box",
            body: "Search actions, workspaces, tabs, agents, projects and plugins. Prefixes narrow it: > % # @ / !",
            shortcut: "palette"),
        Tip(id: "slash", title: "Slash commands, natively",
            body: "Type / in an agent pane for Octet's own menu. Return runs the command; /mcp and /model open their arguments."),
        Tip(id: "marketplace", title: "One place for MCP, plugins, skills and prompts",
            body: "Install into every agent at once. Skills and prompts live once in ~/.agents and link into each of them.",
            shortcut: "marketplace"),
        Tip(id: "hotswap", title: "Apply config without losing the thread",
            body: "After adding an MCP server or plugin, Reload Agents restarts each one with --resume, keeping the conversation.",
            applies: { $0.agentCount > 0 }),
        Tip(id: "recovery", title: "Sessions survive a shutdown",
            body: "Octet remembers each agent's session. When a restart kills them, it offers to resume them where they were.",
            applies: { $0.hasRecoverableSessions }),
        Tip(id: "autoname", title: "Tabs follow the work",
            body: "A tab renames itself to whatever its pane is doing. Rename one yourself and Octet leaves it alone.",
            applies: { $0.hasUnnamedTabs }),
        Tip(id: "idle", title: "Stale workspaces move out of the way",
            body: "Anything untouched for a while drops into the dock below. Pin one to keep it up top.",
            applies: { $0.idleCount > 0 }),
        Tip(id: "worktree", title: "A branch in its own workspace",
            body: "New Worktree in the palette creates the worktree and opens it, so two branches run side by side.",
            applies: { $0.workspaceCount > 1 }),
        Tip(id: "subagents", title: "Watch subagents as they run",
            body: "Install the subagent tabs hook and each subagent an agent spawns opens in its own named tab.",
            applies: { $0.agentCount > 0 }),
        Tip(id: "split", title: "Panes and zoom",
            body: "{splitRight} and {splitDown} split a tab; {toggleZoom} zooms one pane. {focusLeft} and the other arrows move between them.",
            shortcut: "splitRight"),
        Tip(id: "themes", title: "Themes reach the whole window",
            body: "Settings → Appearance restyles the chrome as well as the terminal, and turns motion off if you prefer.",
            shortcut: "settings"),
        Tip(id: "cheatsheet", title: "Every key on one page",
            body: "Help › Keyboard Shortcuts lists them all. Hold ⌘ for a moment to see each tab's number.",
            shortcut: "keyboardShortcuts"),
        Tip(id: "plugins", title: "Plugins without the terminal UI",
            body: "The palette's ! filter runs plugin actions, opens their panes, and reads their logs.",
            applies: { $0.hasPlugins }),
    ]

    /// The next tip to show: the first that applies and hasn't been seen,
    /// starting over once they have all been seen.
    static func next(seen: Set<String>, context: TipContext, deck: [Tip] = all) -> Tip? {
        let relevant = deck.filter { $0.applies(context) }
        return relevant.first { !seen.contains($0.id) } ?? relevant.first
    }

    /// Advances past `current`, so tapping through never repeats immediately.
    static func following(_ current: Tip?, seen: Set<String>, context: TipContext, deck: [Tip] = all) -> Tip? {
        let relevant = deck.filter { $0.applies(context) }
        guard let current, let index = relevant.firstIndex(of: current), relevant.count > 1 else {
            return next(seen: seen, context: context, deck: deck)
        }
        let rotated = Array(relevant[(index + 1)...] + relevant[..<index])
        return rotated.first { !seen.contains($0.id) } ?? rotated.first
    }
}
