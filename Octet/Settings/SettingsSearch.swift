import SwiftUI

/// Every Settings row a search can find. `anchor` is the row's (or group's)
/// title on its page, which the page scrolls to after a jump; `title` is how
/// the result reads out of context.
struct SettingsSearchEntry: Identifiable, Hashable {
    let section: SettingsView.Section
    let title: String
    var anchor: String
    var keywords: [String] = []

    var id: String { "\(section.rawValue)|\(anchor)" }

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

    static let entries: [SettingsSearchEntry] = general + appearance + terminal + statusBar + agents + plugins + motion + keyboard + advanced

    private static let plugins: [SettingsSearchEntry] = [
        .init(.plugins, "Installed plugins", anchor: "Installed", ["plugin", "extension", "enable", "disable", "github", "clone", "repositories"]),
        .init(.plugins, "Plugin folder", ["plugin", "folder", "install", "reload", "manifest"]),
    ]

    private static let general: [SettingsSearchEntry] = [
        .init(.general, "Show tips", ["tip", "card", "sidebar", "hint"]),
        .init(.general, "Confirm before quitting", ["quit", "exit", "close", "background", "prompt"]),
        .init(.general, "Start new tabs and workspaces in", ["folder", "directory", "cwd", "working", "new pane", "home"]),
        .init(.general, "Shell", ["zsh", "bash", "fish", "login shell", "default shell", "path"]),
        .init(.general, "Shell startup mode", ["shell", "login", "non-login", "profile", "zprofile", "rc"]),
        .init(.general, "Move to Idle after", ["idle", "dock", "inactive", "unused", "workspace", "timeout"]),
        .init(.general, "Pinned workspaces", ["pin", "unpin", "workspace"]),
    ]

    private static let statusBar: [SettingsSearchEntry] = [
        .init(.statusBar, "Show status bar", ["status", "bar", "chips", "repo", "git", "branch", "node", "version", "changes"]),
        .init(.statusBar, "Status bar chips", anchor: "Chips", ["chips", "reorder", "prompt", "pull request", "ssh", "worktree", "rebase", "conflicts"]),
        .init(.statusBar, "Add status bar chips", anchor: "Add chips", ["kubernetes", "aws", "docker", "ports", "plugin", "chips", "venv", "terraform"]),
    ]

    private static let appearance: [SettingsSearchEntry] = [
        .init(.appearance, "Follow your terminal's colours", ["import", "theme", "config", "colors"]),
        .init(.appearance, "Match system appearance", ["theme", "light", "dark", "mode", "auto", "system"]),
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
        .init(.appearance, "Split pane borders", anchor: "Borders", ["border", "split", "pane", "outline"]),
        .init(.appearance, "Gaps between panes", ["gap", "split", "pane", "spacing"]),
        .init(.appearance, "Pane scrollbars", ["scrollbar", "scroll bar", "pane"]),
    ]

    private static let terminal: [SettingsSearchEntry] = [
        .init(.terminal, "Scrollback per pane", ["scrollback", "history", "buffer", "lines", "memory", "megabytes"]),
        .init(.terminal, "Terminal text", ["position", "top", "bottom", "align", "output"]),
        .init(.terminal, "Start new tabs with shortcuts", ["splash", "welcome", "empty", "new tab", "start", "shortcuts", "recent"]),
        .init(.terminal, "Copy on select", ["copy", "clipboard", "selection", "mouse"]),
        .init(.terminal, "Confirm copies", ["copy", "clipboard", "toast"]),
        .init(.terminal, "Secure input at password prompts", ["password", "sudo", "secure", "keyboard", "ssh", "security"]),
        .init(.terminal, "Preview long pastes into agents", ["paste", "pasted text", "edit", "long", "claude"]),
        .init(.terminal, "Tidy text copied from agents", ["copy", "clean", "indent", "whitespace", "claude", "paste"]),
        .init(.terminal, "Lines per scroll wheel notch", ["scroll", "mouse", "wheel", "speed", "trackpad"]),
        .init(.terminal, "Use Option as Alt", ["option", "alt", "meta", "keyboard", "key"]),
        .init(.terminal, "Hide mouse pointer while typing", ["mouse", "pointer", "cursor", "hide", "typing"]),
        .init(.terminal, "Warn before pasting risky text", ["paste", "protection", "safe", "warn", "multi-line"]),
        .init(.terminal, "Programs reading the clipboard", ["clipboard", "osc 52", "osc52", "read", "permission"]),
        .init(.terminal, "Inline images", ["image", "picture", "kitty", "graphics"]),
    ]

    private static let agents: [SettingsSearchEntry] = [
        .init(.agents, "Quick answers", ["question", "prompt", "permission", "corner", "choice", "reply"]),
        .init(.agents, "Visual twin", ["terminal", "conversation", "transcript"]),
        .init(.agents, "Open the twin for new agents", ["automatic", "terminal", "conversation"]),
        .init(.agents, "Agent notifications", anchor: "When an agent finishes or needs you",
              ["notification", "notify", "alert", "banner", "done", "finished"]),
        .init(.agents, "Wait before notifying", ["notification", "delay", "wait", "seconds"]),
        .init(.agents, "Play sounds", ["sound", "audio", "chime", "beep"]),
        .init(.agents, "Read live usage from your Claude account",
              ["usage", "allowance", "limit", "quota", "keychain", "claude", "account", "rate"]),
        .init(.agents, "Agents on this machine", anchor: "Agents on this machine",
              ["installed", "discover", "scan", "opencode", "gemini", "cursor", "deepseek", "version", "path"]),
        .init(.agents, "Prompt for agent updates", ["update", "upgrade", "version", "claude", "codex", "pi"]),
        .init(.agents, "Resume agents after a restart", ["resume", "restart", "recover", "reboot", "session"]),
        .init(.agents, "Offer to recover lost sessions", ["recover", "recovery", "crash", "lost", "session", "terminal", "shell"]),
        .init(.agents, "Remote Control for Claude conversations", ["remote", "control", "phone", "mobile", "claude.ai", "app"]),
        .init(.agents, "Agent accounts", ["account", "login", "profile", "work", "personal", "switch", "sign in", "claude_config_dir", "codex_home"]),
        .init(.agents, "Keep the Mac awake while agents work", ["sleep", "caffeinate", "awake", "battery", "power", "amphetamine"]),
        .init(.agents, "Checkpoint before each agent turn", ["undo", "rewind", "restore", "snapshot", "checkpoint", "revert", "git"]),
        .init(.agents, "Keep closed tabs running", ["reopen", "closed", "undo", "accident", "tab", "recover"]),
        .init(.agents, "When you run an agent in a terminal",
              ["claude", "codex", "opencode", "open", "native", "conversation", "chat", "terminal", "interface", "launch"]),
        .init(.agents, "Offer Octet's view over a running agent",
              ["banner", "offer", "dismiss", "conversation", "chat", "claude", "codex", "opencode"]),
        .init(.agents, "Octet's command line", ["prompt", "editor", "command line", "history", "suggestion", "highlight", "autosuggest"]),
        .init(.agents, "Paste images as files", ["paste", "image", "screenshot", "clipboard", "file"]),
        .init(.agents, "Command specs", ["completion", "autocomplete", "fig", "spec", "install"]),
        .init(.agents, "Name tabs after their work", ["tab", "title", "rename", "name", "auto"]),
        .init(.agents, "Restore recent terminal output", ["restore", "history", "output", "scrollback", "secrets"]),
        .init(.agents, "Agent integrations", ["integration", "claude", "codex", "install", "hook"]),
        .init(.agents, "Subagent tabs", ["subagent", "hook", "background tab", "transcript", "auto close", "close tab", "finished"]),
        .init(.agents, "Subagent finished sound", ["subagent", "sound", "audio", "chime", "finished", "done"]),
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

/// Search results in place of a page: the matching rows of every section,
/// grouped under the section they live in.
struct SettingsSearchResults: View {
    let query: String
    let results: [SettingsSearchEntry]
    let open: (SettingsSearchEntry) -> Void

    var body: some View {
        if results.isEmpty {
            VStack(spacing: 8) {
                OctetIcon("magnifyingglass", size: 35)
                    .foregroundStyle(Theme.textTertiary)
                Text("No settings match")
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundStyle(Theme.textPrimary)
                Text("Nothing is called \u{201C}\(query.trimmingCharacters(in: .whitespaces))\u{201D}. Try a shorter or different word.")
                    .font(Theme.uiFont)
                    .foregroundStyle(Theme.textSecondary)
                    .multilineTextAlignment(.center)
            }
            .frame(maxWidth: .infinity)
            .padding(.top, 60)
            .accessibilityElement(children: .combine)
        } else {
            ForEach(SettingsView.Section.allCases) { section in
                let rows = results.filter { $0.section == section }
                if !rows.isEmpty {
                    SettingsGroup(title: section.title) {
                        ForEach(Array(rows.enumerated()), id: \.element.id) { index, entry in
                            if index > 0 { SettingsDivider() }
                            SearchResultRow(entry: entry, isFirst: entry == results.first) { open(entry) }
                        }
                    }
                }
            }
        }
    }
}

private struct SearchResultRow: View {
    let entry: SettingsSearchEntry
    /// Return in the search field opens the first result.
    let isFirst: Bool
    let action: () -> Void
    @State private var hovered = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: 10) {
                OctetIcon(entry.section.symbol, size: 15)
                    .foregroundStyle(Theme.textTertiary)
                    .frame(width: 16)
                Text(entry.title).font(.system(size: 13)).foregroundStyle(Theme.textPrimary)
                Spacer(minLength: 8)
                if isFirst {
                    Text("↩").font(Theme.captionFont).foregroundStyle(Theme.textTertiary)
                }
                OctetIcon("chevron.right", size: 14)
                    .foregroundStyle(Theme.textTertiary)
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 9)
            .background(hovered ? Theme.hover : Color.clear)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hovered = $0 }
        .accessibilityLabel("\(entry.title), in \(entry.section.title)")
        .accessibilityHint("Opens the \(entry.section.title) settings")
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

/// Help › Keyboard Shortcuts: opens Settings on the Keyboard page.
struct KeyboardShortcutsMenuItem: View {
    @Environment(\.openSettings) private var openSettings
    @AppStorage(SettingsView.sectionKey) private var section: SettingsView.Section = .general

    var body: some View {
        Button("Keyboard Shortcuts") {
            section = .keyboard
            NSApp.activate(ignoringOtherApps: true)
            openSettings()
        }
    }
}
