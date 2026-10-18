import AppKit
import SwiftUI

/// Prompt links in Octet: copying one for a conversation's last prompt (or
/// any text), and opening one, which starts a new conversation in the
/// link's folder with the prompt typed in, never sent, after asking.
@MainActor
enum PromptLinks {
    /// The link for `session`'s last prompt, in its folder and agent.
    static func link(for session: AgentSession) -> URL? {
        PromptLink.lastPrompt(in: session.conversation.items).flatMap {
            PromptLink.link(prompt: $0, dir: session.cwd, agent: session.engine.rawValue)
        }
    }

    static func copyLink(for session: AgentSession) {
        guard let url = link(for: session) else {
            ToastCenter.shared.info("No prompt to link to", detail: "Send a message first.")
            return
        }
        copy(url)
    }

    static func copy(_ url: URL) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(url.absoluteString, forType: .string)
        ToastCenter.shared.info("Copied the prompt link",
                                detail: "Opening it starts a new conversation with the prompt typed in, not sent.")
    }

    // MARK: Opening

    /// `octet://new`: asks, then opens a new conversation in `dir` (or the
    /// workspace in front) with `prompt` in its composer.
    static func open(prompt: String, dir: String?, agent: String?, window: WindowContext) {
        let engine: AgentSession.Engine
        if let agent {
            guard let named = AgentSession.Engine(rawValue: agent) else {
                ToastCenter.shared.fail(nil, "Octet can't hold a conversation with \(agent)",
                                        detail: "Prompt links open Claude, Codex, OpenCode, Pi or Qwen.")
                return
            }
            engine = named
        } else {
            engine = .claude
        }
        if let dir {
            var isDirectory: ObjCBool = false
            guard FileManager.default.fileExists(atPath: dir, isDirectory: &isDirectory), isDirectory.boolValue else {
                ToastCenter.shared.fail(nil, "There's no folder at \((dir as NSString).abbreviatingWithTildeInPath)")
                return
            }
        }
        let place = dir.map { " in \(($0 as NSString).abbreviatingWithTildeInPath)" } ?? ""
        ConfirmCenter.shared.ask(
            title: "Open a new \(engine.displayName) conversation\(place)?",
            message: "A link asked Octet to, with this prompt. It's typed into the message box for you to read and send yourself; nothing runs until you do.",
            detail: prompt, confirmTitle: "Open"
        ) { _ in
            start(engine: engine, prompt: prompt, dir: dir, window: window)
        }
    }

    private static func start(engine: AgentSession.Engine, prompt: String, dir: String?, window: WindowContext,
                              attempts: Int = 0) {
        let store = window.store
        let workspace: String? = {
            guard let dir else { return window.focusedWorkspace?.workspaceId }
            return store.snapshot.workspaces.first { store.snapshot.directory(ofWorkspace: $0.workspaceId) == dir }?.workspaceId
        }()
        guard let workspace else {
            // A folder with no workspace yet: open one, then start there once
            // it's up (or, failing that, in the workspace in front).
            if attempts == 0, let dir { window.openProject(path: dir) }
            if attempts < 12 {
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.25) {
                    start(engine: engine, prompt: prompt, dir: dir, window: window, attempts: attempts + 1)
                }
            } else if let front = window.focusedWorkspace?.workspaceId {
                begin(engine: engine, prompt: prompt, cwd: dir, workspaceId: front, window: window)
            }
            return
        }
        if workspace != window.focusedWorkspace?.workspaceId { window.focusWorkspace(workspace) }
        begin(engine: engine, prompt: prompt, cwd: dir, workspaceId: workspace, window: window)
    }

    private static func begin(engine: AgentSession.Engine, prompt: String, cwd: String?, workspaceId: String,
                              window: WindowContext) {
        window.editor.dismiss()
        let folder = cwd ?? window.store.snapshot.directory(ofWorkspace: workspaceId) ?? NSHomeDirectory()
        let session = AgentCenter.shared.newConversation(workspaceId: workspaceId, cwd: folder, engine: engine)
        session.prefillComposer(prompt)
    }

    // MARK: Palette

    static func paletteItems(window: WindowContext) -> [PaletteItem] {
        var items: [PaletteItem] = []
        let workspace = window.focusedWorkspace?.workspaceId
        if let session = AgentCenter.shared.active(in: workspace), let url = link(for: session) {
            items.append(PaletteItem(
                id: "action.copyPromptLink", kind: .action, title: "Copy Prompt Link",
                subtitle: "A link that opens a new \(session.engine.displayName) conversation with this one's last prompt",
                keywords: ["share", "url", "octet://", "prompt", "link"], icon: .symbol("prompt.link"),
                effect: .run { copy(url) }
            ))
        }
        let folder = workspace.flatMap { window.store.snapshot.directory(ofWorkspace: $0) }
        items.append(PaletteItem(
            id: "action.newPromptLink", kind: .action, title: "Copy Prompt Link for…",
            subtitle: "Type a prompt; the link opens it in a new Claude conversation\(folder.map { " in \(($0 as NSString).lastPathComponent)" } ?? "")",
            keywords: ["share", "url", "octet://", "prompt", "link", "new"], icon: .symbol("prompt.link"),
            effect: .prompt(title: "Prompt link", placeholder: "The prompt the link should type in…", initial: "") { text in
                guard let url = PromptLink.link(prompt: text, dir: folder, agent: AgentSession.Engine.claude.rawValue) else { return }
                copy(url)
            }
        ))
        return items
    }
}
