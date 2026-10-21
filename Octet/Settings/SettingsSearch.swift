import SwiftUI

/// Every Settings row a search can find. `anchor` is the row's (or group's)
/// title on its page, which the page scrolls to after a jump; `title` is how
/// the result reads out of context.
struct SettingsSearchEntry: Identifiable, Hashable {
    let section: SettingsView.Section
    let title: String
    var anchor: String
    var keywords: [String] = []

    /// The title too: several entries can jump to one group's anchor.
    var id: String { "\(section.rawValue)|\(anchor)|\(title)" }

    init(_ section: SettingsView.Section, _ title: String, anchor: String? = nil, _ keywords: [String] = []) {
        self.section = section
        self.title = title
        self.anchor = anchor ?? title
        self.keywords = keywords
    }

    /// Every word of the query has to appear in the title or a keyword.
    func matches(_ words: [String]) -> Bool {
        let haystack = ([title] + keywords).joined(separator: " ").lowercased()
        return words.allSatisfy { haystack.contains($0) }
    }
}

enum SettingsSearchIndex {
    static func search(_ query: String) -> [SettingsSearchEntry] {
        let words = query.lowercased().split(whereSeparator: \.isWhitespace).map(String.init)
        guard !words.isEmpty else { return [] }
        return entries.filter { $0.matches(words) }
    }

    static let entries: [SettingsSearchEntry] = general + appearance + terminal + statusBar + notch + notifications + agents + agentsMore
        + integrations + plugins + motion + keyboard + advanced

    private static let plugins: [SettingsSearchEntry] = [
        .init(.plugins, "Installed plugins", anchor: "Installed", ["plugin", "extension", "enable", "disable", "github", "clone", "repositories"]),
        .init(.plugins, "Plugin folder", ["plugin", "folder", "install", "reload", "manifest"]),
    ]

    private static let general: [SettingsSearchEntry] = [
        .init(.general, "Confirm before quitting", ["quit", "exit", "close", "background", "prompt"]),
        .init(.general, "Start new tabs and workspaces in", ["folder", "directory", "cwd", "working", "new pane", "home", "session"]),
        .init(.general, "Shell", ["zsh", "bash", "fish", "login shell", "default shell", "path"]),
        .init(.general, "Shell startup mode", ["shell", "login", "non-login", "profile", "zprofile", "rc"]),
        .init(.general, "Move to Idle after", ["idle", "dock", "inactive", "unused", "workspace", "timeout"]),
        .init(.general, "Sleep idle workspaces after", ["idle", "sleep", "hibernate", "close", "unused", "wake", "workspace"]),
        .init(.general, "Pinned workspaces", ["pin", "unpin", "workspace"]),
        .init(.general, "Show tips", ["tip", "card", "sidebar", "hint", "help"]),
    ]

    private static let notch: [SettingsSearchEntry] = [
        .init(.notch, "Hover delay", ["milliseconds", "speed", "delay", "120", "hover"]),
        .init(.notch, "Enable Notch", ["notch", "island", "dynamic island", "notchnook", "menu bar", "pill", "top", "glance"]),
        .init(.notch, "Open the notch with", ["hover", "click", "expand", "open", "trigger"]),
        .init(.notch, "Show on", ["display", "monitor", "screen", "main", "pointer", "all", "external"]),
        .init(.notch, "Show on displays without a notch", ["external", "monitor", "pill", "no notch", "floating"]),
        .init(.notch, "Peek when an agent finishes or needs you", ["peek", "banner", "notification", "finished", "needs you", "alert"]),
        .init(.notch, "Show in full screen", ["full screen", "fullscreen", "hide", "space"]),
        .init(.notch, "Haptic feedback on open", ["haptic", "trackpad", "tap", "feedback", "vibrate"]),
        .init(.notch, "Notch size", ["compact", "regular", "small", "large", "width"]),
        .init(.notch, "Notch pages", ["tabs", "agents", "now", "usage", "actions", "pages", "sections"]),
    ]

    private static let statusBar: [SettingsSearchEntry] = [
        .init(.statusBar, "Show status bar", ["status", "bar", "chips", "repo", "git", "branch", "node", "version", "changes"]),
        .init(.statusBar, "Status bar chips", anchor: "Chips", ["chips", "reorder", "prompt", "pull request", "ssh", "worktree", "rebase", "conflicts"]),
        .init(.statusBar, "Add status bar chips", anchor: "Add chips", ["kubernetes", "aws", "docker", "ports", "plugin", "chips", "venv", "terraform"]),
    ]

    private static let appearance: [SettingsSearchEntry] = [
        .init(.appearance, "Follow your terminal's colours", ["import", "theme", "config", "colors"]),
        .init(.appearance, "Color scheme", ["theme", "light", "dark", "mode", "auto", "system", "appearance", "match"]),
        .init(.appearance, "Match system appearance", anchor: "Color scheme", ["theme", "light", "dark", "mode", "auto", "system"]),
        .init(.appearance, "Theme", ["theme", "color", "colour", "palette", "scheme", "swatch"]),
        .init(.appearance, "Font", ["font", "typeface", "family", "monospace", "jetbrains"]),
        .init(.appearance, "Font size", ["font", "text size", "zoom", "bigger", "smaller", "points", "pt"]),
        .init(.appearance, "Line height", ["line", "spacing", "leading", "font"]),
        .init(.appearance, "Thicken text", ["bold", "weight", "stroke", "font", "thick"]),
        .init(.appearance, "Cursor shape", anchor: "Shape", ["cursor", "block", "bar", "underline", "caret"]),
        .init(.appearance, "Cursor blink", anchor: "Blink", ["cursor", "blink", "caret"]),
        .init(.appearance, "Terminal opacity", ["opacity", "transparency", "transparent", "alpha", "see-through", "window"]),
        .init(.appearance, "Blur behind terminal", ["blur", "vibrancy", "transparency", "opacity", "window"]),
        .init(.appearance, "Window padding", anchor: "Padding", ["padding", "margin", "spacing", "compact", "roomy", "window"]),
    ]

    private static let terminal: [SettingsSearchEntry] = [
        .init(.terminal, "Scrollback per pane", ["scrollback", "history", "buffer", "lines", "memory", "megabytes"]),
        .init(.terminal, "Terminal text", ["position", "top", "bottom", "align", "output"]),
        .init(.terminal, "Start new tabs with shortcuts", ["splash", "welcome", "empty", "new tab", "start", "shortcuts", "recent"]),
        .init(.terminal, "Copy on select", ["copy", "clipboard", "selection", "mouse"]),
        .init(.terminal, "Confirm copies", ["copy", "clipboard", "toast"]),
        .init(.terminal, "Shell integration", ["osc 133", "prompt", "marks", "exit status", "zsh", "fish", "duration"]),
        .init(.terminal, "Secure input at password prompts", ["password", "sudo", "secure", "keyboard", "ssh", "security"]),
        .init(.terminal, "Preview long pastes into agents", ["paste", "pasted text", "edit", "long", "claude"]),
        .init(.terminal, "Tidy text copied from agents", ["copy", "clean", "indent", "whitespace", "claude", "paste"]),
        .init(.terminal, "Lines per scroll wheel notch", ["scroll", "mouse", "wheel", "speed", "trackpad"]),
        .init(.terminal, "Use Option as Alt", ["option", "alt", "meta", "keyboard", "key"]),
        .init(.terminal, "Hide mouse pointer while typing", ["mouse", "pointer", "cursor", "hide", "typing"]),
        .init(.terminal, "Warn before pasting risky text", ["paste", "protection", "safe", "warn", "multi-line"]),
        .init(.terminal, "Programs reading the clipboard", ["clipboard", "osc 52", "osc52", "read", "permission"]),
        .init(.terminal, "Inline images", ["image", "picture", "kitty", "graphics"]),
        .init(.terminal, "Open local links in the Browser plane", ["link", "url", "localhost", "browser", "preview", "click", "dev server"]),
        .init(.terminal, "Open them with a plain click", ["link", "url", "localhost", "browser", "preview", "click", "plain"]),
        .init(.terminal, "Offer to preview new servers", ["server", "port", "localhost", "browser", "preview", "dev server", "card", "toast"]),
        .init(.terminal, "Let agents read the sidebar terminal", anchor: "Sidebar terminal",
              ["agent", "claude", "codex", "mcp", "read", "output", "logs", "right panel", "octet-terminal", "privacy"]),
        .init(.terminal, "Let agents suggest commands in the sidebar terminal", anchor: "Sidebar terminal",
              ["agent", "claude", "codex", "mcp", "command", "run", "paste", "suggest", "right panel", "octet-terminal"]),
    ]

    private static let notifications: [SettingsSearchEntry] = [
        .init(.notifications, "Agent needs input", ["notification", "notify", "question", "permission", "approve", "waiting"]),
        .init(.notifications, "Agent finished", ["notification", "notify", "done", "finished", "complete"]),
        .init(.notifications, "Agent failed", ["notification", "notify", "error", "failed", "crash"]),
        .init(.notifications, "Suppress while the agent is on screen", ["notification", "quiet", "visible", "looking", "focus", "suppress"]),
        .init(.notifications, "Terminal bell", ["bell", "beep", "bel", "sound", "bounce", "dock"]),
        .init(.notifications, "Notifications from Octet", ["permission", "allow", "denied", "system settings", "macos", "notification center"]),
        .init(.notifications, "Send a test notification", ["test", "try", "notification", "check", "permission"]),
        .init(.notifications, "Notices on your phone", ["phone", "ntfy", "push", "mobile", "topic"]),
        .init(.notifications, "ntfy server", ["phone", "ntfy", "server", "self-hosted"]),
    ]

    private static let integrations: [SettingsSearchEntry] = [
        .init(.integrations, "Let agents read issues", ["issue", "github", "linear", "jira", "tracker", "mcp", "tickets"]),
        .init(.integrations, "Issue trackers", ["issue", "github", "linear", "jira", "tracker", "tickets"]),
        .init(.integrations, "Hand work to other agents", anchor: "Delegation", ["delegate", "delegation", "review", "codex", "second opinion"]),
    ]

    private static let agentsMore: [SettingsSearchEntry] = [
        .init(.agents, "Default agent", ["default", "agent", "claude", "codex", "opencode", "new conversation", "engine"]),
        .init(.agents, "Hold Space to talk", ["voice", "speech", "dictation", "talk", "microphone"]),
        .init(.agents, "Running agents", ["agent", "terminal", "conversation", "twin"]),
        .init(.terminal, "Octet's Tab completions", ["tab", "completion", "complete", "shell"]),
        .init(.general, "Name workspaces after their work", ["workspace", "title", "rename", "name", "auto"]),
    ]

    private static let agents: [SettingsSearchEntry] = [
        .init(.notifications, "Quick answers", ["question", "prompt", "permission", "corner", "choice", "reply"]),
        .init(.agents, "Visual twin", ["terminal", "conversation", "transcript"]),
        .init(.agents, "Open the twin for new agents", ["automatic", "terminal", "conversation"]),
        .init(.waits, "Let agents set waits", anchor: "Waits",
              ["wait", "waiting", "blocked", "pull request", "merged", "release", "later", "remind", "follow up", "octet-waits", "mcp"]),
        .init(.waits, "Offer a wait from a reply", anchor: "Waits", ["wait", "suggest", "once", "after", "banner"]),
        .init(.waits, "Pause all check-ins", anchor: "Check-ins",
              ["check-in", "checkin", "check in", "pause", "remind", "long", "days", "weeks", "wake", "schedule"]),
        .init(.waits, "New check-ins", anchor: "Check-ins", ["check-in", "mode", "wake", "remind", "default", "both"]),
        .init(.waits, "Say when a session looks stalled", anchor: "Check-ins",
              ["stall", "stalled", "stuck", "hung", "idle", "working", "hours", "threshold", "check-in"]),
        .init(.waits, "Quiet hours", anchor: "Check-ins", ["quiet", "night", "sleep", "do not disturb", "wake", "check-in", "hours"]),
        .init(.waits, "Remind me when Octet is closed", anchor: "Check-ins",
              ["notification", "notify", "closed", "quit", "macos", "remind", "check-in", "local"]),
        .init(.notifications, "Recap when you come back", ["recap", "away", "catch up", "summary", "while you were away", "back", "digest"]),
        .init(.notifications, "Recap: away for at least", anchor: "Away for at least", ["recap", "away", "minutes", "threshold"]),
        .init(.notifications, "Agent notifications", anchor: "When an agent finishes or needs you",
              ["notification", "notify", "alert", "banner", "done", "finished"]),
        .init(.notifications, "Wait before notifying", ["notification", "delay", "wait", "seconds"]),
        .init(.notifications, "Play sounds", ["sound", "audio", "chime", "beep"]),
        .init(.accounts, "Read live usage from your Claude account",
              ["usage", "allowance", "limit", "quota", "keychain", "claude", "account", "rate"]),
        .init(.agents, "Agents on this machine", anchor: "Agents on this machine",
              ["installed", "discover", "scan", "opencode", "gemini", "cursor", "deepseek", "version", "path"]),
        .init(.agents, "Prompt for agent updates", ["update", "upgrade", "version", "claude", "codex", "pi"]),
        .init(.recovery, "Resume agents after a restart", ["resume", "restart", "recover", "reboot", "session"]),
        .init(.agents, "Move agents to the project they work in", ["cd", "directory", "folder", "project", "repository", "wrong", "move", "relocate", "cwd"]),
        .init(.recovery, "Offer to recover lost sessions", ["recover", "recovery", "crash", "lost", "session", "terminal", "shell"]),
        .init(.agents, "Remote Control for Claude conversations", ["remote", "control", "phone", "mobile", "claude.ai", "app"]),
        .init(.general, "Hotkey from any app", ["hotkey", "quake", "global", "shortcut", "summon", "dropdown"]),
        .init(.general, "Drop down from the top", ["hotkey", "quake", "dropdown", "drop-down", "full screen", "visor", "guake"]),
        .init(.accounts, "Agent accounts", ["account", "login", "profile", "work", "personal", "switch", "sign in", "claude_config_dir", "codex_home"]),
        .init(.agents, "Keep the Mac awake while agents work", ["sleep", "caffeinate", "awake", "battery", "power", "amphetamine"]),
        .init(.recovery, "Checkpoint before each agent turn", ["undo", "rewind", "restore", "snapshot", "checkpoint", "revert", "git"]),
        .init(.recovery, "Keep closed tabs running", ["reopen", "closed", "undo", "accident", "tab", "recover"]),
        .init(.recovery, "Ask before stopping running terminals", ["confirm", "close", "stop", "agent", "command", "warn", "pane"]),
        .init(.agents, "When you run an agent in a terminal",
              ["claude", "codex", "opencode", "open", "native", "conversation", "chat", "terminal", "interface", "launch"]),
        .init(.agents, "Offer Octet's view over a running agent",
              ["banner", "offer", "dismiss", "conversation", "chat", "claude", "codex", "opencode"]),
        .init(.terminal, "Octet's command line", ["prompt", "editor", "command line", "history", "suggestion", "highlight", "autosuggest"]),
        .init(.terminal, "Accept a suggestion with", ["suggestion", "autosuggest", "accept", "tab", "arrow", "right", "key"]),
        .init(.integrations, "Talk to other Macs", ["other macs", "peer", "pair", "network", "remote", "delegate", "machine", "lan", "bonjour"]),
        .init(.terminal, "Paste images as files", ["paste", "image", "screenshot", "clipboard", "file"]),
        .init(.terminal, "Command specs", ["completion", "autocomplete", "fig", "spec", "install"]),
        .init(.general, "Name tabs after their work", ["tab", "title", "rename", "name", "auto"]),
        .init(.recovery, "Restore recent terminal output", ["restore", "history", "output", "scrollback", "secrets"]),
        .init(.agents, "Agent integrations", ["integration", "claude", "codex", "install", "hook"]),
        .init(.agents, "Subagent tabs", ["subagent", "hook", "background tab", "transcript", "auto close", "close tab", "finished"]),
        .init(.notifications, "Subagent finished sound", ["subagent", "sound", "audio", "chime", "finished", "done"]),
    ]

    private static let motion: [SettingsSearchEntry] = [
        .init(.motion, "Enable animations", ["animation", "motion", "instant", "transition"]),
        .init(.motion, "Follow system Reduce Motion", ["reduce motion", "accessibility", "animation"]),
        .init(.motion, "Animate", ["animation", "motion"]),
    ]

    /// One entry per shortcut on the Keyboard page.
    private static let keyboard: [SettingsSearchEntry] = OctetShortcut.groups.flatMap { group in
        group.shortcuts.map { shortcut in
            SettingsSearchEntry(.keyboard, shortcut.title, ["shortcut", "keyboard", "key", "hotkey", group.title.lowercased()])
        }
    }

    private static let advanced: [SettingsSearchEntry] = [
        .init(.advanced, "Worktree folder", ["worktree", "git", "branch", "checkout", "folder"]),
        .init(.advanced, "Set up new worktrees", ["env", ".env", "setup", "script", "port", "conductor", "worktree", "copy"]),
        .init(.advanced, "Check for engine updates", ["update", "upgrade", "engine", "version"]),
        .init(.advanced, "Update channel", ["update", "preview", "beta", "stable", "channel"]),
        .init(.advanced, "Allow a nested session", ["nested", "session", "inside"]),
        .init(.advanced, "Session", ["session", "name"]),
        .init(.advanced, "Generated config", ["config", "toml", "reload", "reveal", "file"]),
        .init(.advanced, "Terminal engine plugins", ["plugin", "installed", "engine"]),
        .init(.advanced, "Restore default settings", ["reset", "defaults", "restore", "factory"]),
    ]
}

/// A search result in Settings' sidebar, after T3 Code's: the section's
/// icon, then two lines, the setting and the section it lives in. `active`
/// is the one Return opens, which the pointer and ↑/↓ both move.
struct SettingsSearchResultRow: View {
    let entry: SettingsSearchEntry
    let active: Bool
    let hover: () -> Void
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(alignment: .top, spacing: 8) {
                OctetIcon(entry.section.symbol, size: 15)
                    .foregroundStyle(active ? Theme.textPrimary : Theme.textTertiary)
                    .frame(width: 18)
                    .padding(.top, 2)
                VStack(alignment: .leading, spacing: 1) {
                    Text(entry.title)
                        .font(Theme.interfaceFont(14, weight: .medium))
                        .foregroundStyle(Theme.textPrimary)
                        .lineLimit(1)
                    Text(entry.section.title)
                        .font(Theme.interfaceFont(11))
                        .foregroundStyle(Theme.textTertiary)
                        .lineLimit(1)
                }
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 5)
            .frame(minHeight: 40)
            .background(RoundedRectangle(cornerRadius: Theme.controlRadius)
                .fill(active ? Theme.cardSelected : .clear))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { if $0 { hover() } }
        .accessibilityLabel("\(entry.title), in \(entry.section.title)")
        .accessibilityHint("Opens the \(entry.section.title) settings")
        .accessibilityAddTraits(active ? [.isButton, .isSelected] : .isButton)
    }
}

// MARK: - Menus

/// Help menu items. Octet has no help book, so help is the README.
enum OctetHelp {
    static let readmeURL = URL(string: "https://github.com/JackTPatterson/octet#readme")!

    static func openReadme() {
        NSWorkspace.shared.open(readmeURL)
    }
}
