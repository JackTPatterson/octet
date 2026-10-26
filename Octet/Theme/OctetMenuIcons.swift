import Foundation

/// An icon for a menu item that has none, from the verb its title starts
/// with ("Copy Path", "Rename…", "Close Others"), so every context menu
/// reads with icons without each one naming them. An item that sets its own
/// icon, or whose title says nothing about what it does (a branch, a model
/// or a file), is left alone.
enum OctetMenuIcons {
    /// Words a title starts with, and the icon for them. Earlier rows win, so
    /// the specific ones ("copy link") sit above the general ("copy").
    private static let rules: [(starts: [String], icon: String)] = [
        (["reveal in finder", "show in finder", "show in folder", "reveal in"], "folder"),
        (["open in browser", "open on github", "open in github", "open link", "open url", "open on the web", "open in safari"], "arrow.up.right"),
        (["open in terminal", "open terminal", "new terminal", "run in terminal", "run in"], "terminal"),
        (["open pull request", "view pull request", "create pull request", "create pr", "open pr"], "pull.request"),
        (["split right", "split left", "split beside", "show beside"], "rectangle.split.2x1"),
        (["split down", "split up", "split below", "split above"], "rectangle.split.1x2"),
        (["copy link", "copy url", "copy path", "copy relative", "copy absolute", "copy branch", "copy as", "copy message", "copy output",
          "copy text", "copy code", "copy command", "copy id", "copy session", "copy"], "doc.on.doc"),
        (["mark as unread", "mark unread"], "circle.dot"),
        (["mark as read", "mark read", "mark all", "mark as done", "mark done", "mark complete", "complete", "done"], "checkmark.circle"),
        (["unpin"], "pin.slash"),
        (["pin"], "pin"),
        (["rename", "edit", "modify", "change name"], "pencil"),
        (["delete", "remove", "discard", "trash", "forget", "clear", "erase"], "trash"),
        (["close", "dismiss", "cancel", "quit"], "xmark"),
        (["hide"], "eye.slash"),
        (["show", "view", "preview", "inspect"], "eye"),
        (["new tab", "new workspace", "new conversation", "new window", "new file", "new folder", "new", "add", "create", "start", "install"], "plus"),
        (["duplicate", "clone", "fork"], "rectangle.on.rectangle"),
        (["refresh", "reload", "retry", "try again", "regenerate", "resend", "rerun", "re-run", "restart", "sync"], "arrow.clockwise"),
        (["undo", "revert", "restore", "rewind", "roll back"], "undo"),
        (["stop", "interrupt", "kill", "terminate", "abort"], "xmark.octagon"),
        (["run", "play", "resume", "continue", "launch", "execute"], "play"),
        (["save", "export", "download"], "square.and.arrow.down"),
        (["search", "find"], "magnifyingglass"),
        (["settings", "preferences", "configure", "options"], "gearshape"),
        (["snooze", "sleep", "remind"], "moon.zzz"),
        (["archive", "stash"], "square.stack.3d.up"),
        (["approve", "accept", "allow", "apply", "confirm", "keep"], "checkmark"),
        (["reject", "deny", "decline", "refuse"], "xmark"),
        (["merge"], "merge"),
        (["checkout", "switch to", "switch branch", "branch", "worktree"], "branch"),
        (["commit"], "commit"),
        (["tag"], "tag"),
        (["compare", "diff", "review"], "doc.diff"),
        (["reply", "comment", "quote", "note", "ask"], "text.bubble"),
        (["move", "send", "go to", "jump", "focus", "scroll to", "navigate", "next", "previous"], "arrow.right"),
        (["info", "details", "properties", "about"], "info.circle.fill"),
        (["color", "theme", "appearance"], "paintpalette"),
        (["link", "attach", "connect"], "link.badge.plus"),
        (["expand", "unfold"], "chevron.down"),
    ]

    static func guess(_ title: String) -> String? {
        let text = title.lowercased().trimmingCharacters(in: .whitespaces)
        // Long titles are names and sentences, not verbs.
        guard !text.isEmpty, text.count <= 42 else { return nil }
        for rule in rules {
            for start in rule.starts where text == start || text.hasPrefix(start + " ") || text.hasPrefix(start + "…")
                || text.hasPrefix(start + "...") {
                return rule.icon
            }
        }
        return nil
    }
}
