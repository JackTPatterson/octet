import AppKit
import SwiftUI
import UniformTypeIdentifiers

/// What can be done with a whole conversation, in its tab's menu: go on in
/// a fork of it, see what it changed, share it, and check its MCP servers.
struct ConversationActionsMenu: View {
    @EnvironmentObject private var window: WindowContext
    @ObservedObject var session: AgentSession

    var body: some View {
        Button("Session Changes") {
            guard let commit = session.baselineCommit else { return }
            window.ui.review = DiffReviewModel(directory: session.cwd,
                                               since: .since(commit: commit, name: "the conversation's start"))
        }
        .disabled(session.baselineCommit == nil)
        .help("Everything changed in the folder since this conversation's first message")
        Button("Fork Conversation") { session.fork() }
            .disabled(!session.canFork)
        Button("Move To…") { moveToFolder() }
            .disabled(!session.canMove)
            .help(session.engine == .claude
                  ? "Carry on with this conversation in another folder; Claude Code resumes it there"
                  : "Only Claude Code conversations can move: \(session.engine.displayName) ties a thread to its folder")
        if session.engine == .pi {
            Button("Session Tree…") {
                session.piSessionTree { lines in
                    ConfirmCenter.shared.show(
                        title: "Session tree",
                        message: lines.isEmpty ? "No messages yet." : PiSessionTree.text(lines),
                        detail: "● marks the branch this conversation is on. Rewind to an earlier message to start a new branch from it.")
                }
            }
        }
        if session.hasMCP {
            Button("MCP Servers…") { MCPServersDialog.show(session) }
        }
        Divider()
        Button("Copy as Markdown") {
            copy(markdown)
            ToastCenter.shared.info("Copied the conversation", detail: "As Markdown")
        }
        .disabled(session.conversation.items.isEmpty)
        Button("Save as Markdown…") { save() }
            .disabled(session.conversation.items.isEmpty)
        if session.engine == .opencode {
            Button("Copy Share Link") {
                session.shareOpenCode { result in
                    switch result {
                    case .success(let url):
                        copy(url.absoluteString)
                        ToastCenter.shared.info("Copied the share link", detail: url.absoluteString)
                    case .failure(let error):
                        ToastCenter.shared.fail(nil, "Couldn't share the conversation", detail: error.localizedDescription)
                    }
                }
            }
            .help("OpenCode publishes the conversation and gives a link anyone can open")
        }
    }

    private var markdown: String {
        ConversationExport.markdown(title: session.title, agent: session.engine.displayName,
                                    cwd: session.cwd, items: session.conversation.items)
    }

    /// Picks the folder, moves the conversation there, and shows it in the
    /// workspace for that folder when one is open.
    private func moveToFolder() {
        let panel = NSOpenPanel()
        panel.title = "Move the Conversation"
        panel.message = "Choose the folder to carry on in. Claude Code resumes the conversation there."
        panel.prompt = "Move"
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.canCreateDirectories = true
        panel.allowsMultipleSelection = false
        panel.directoryURL = URL(fileURLWithPath: session.cwd)
        guard panel.runModal() == .OK, let url = panel.url else { return }
        let folder = url.standardizedFileURL.path
        let snapshot = window.store.snapshot
        let workspace = snapshot.workspaces.first { snapshot.directory(ofWorkspace: $0.workspaceId) == folder }
        switch session.move(to: folder, workspaceId: workspace?.workspaceId) {
        case .success(let moved):
            if let workspace, workspace.workspaceId != session.workspaceId { window.focusWorkspace(workspace.workspaceId) }
            ToastCenter.shared.info("Moved to \(abbreviateHome(folder))",
                                    detail: "\(moved.title) carries on there; its transcript was copied into that folder's project.")
        case .failure(let error):
            ToastCenter.shared.fail(nil, "Couldn't move the conversation", detail: error.localizedDescription)
        }
    }

    private func copy(_ text: String) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
    }

    private func save() {
        let panel = NSSavePanel()
        panel.nameFieldStringValue = session.title.replacingOccurrences(of: "/", with: "-") + ".md"
        panel.allowedContentTypes = [UTType(filenameExtension: "md") ?? .plainText]
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do {
            try markdown.write(to: url, atomically: true, encoding: .utf8)
        } catch {
            ToastCenter.shared.fail(nil, "Couldn't save the conversation", detail: error.localizedDescription)
        }
    }
}
