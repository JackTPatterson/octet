import AppKit

/// Moving conversations to another folder from the UI: the folder picker,
/// the move itself for one conversation or a workspace's, and the toast
/// that says how it went. See `AgentSession.move(to:)`.
@MainActor
enum ConversationMover {
    /// Asks for the folder; nil when cancelled.
    static func pickFolder(startingAt directory: String) -> String? {
        let panel = NSOpenPanel()
        panel.title = "Move the Conversation"
        panel.message = "Choose the folder to carry on in. Claude Code resumes the conversation there."
        panel.prompt = "Move"
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.canCreateDirectories = true
        panel.allowsMultipleSelection = false
        panel.directoryURL = URL(fileURLWithPath: directory)
        guard panel.runModal() == .OK, let url = panel.url else { return nil }
        return url.standardizedFileURL.path
    }

    /// Moves every conversation that can be moved to `folder`, into the
    /// workspace for that folder when one is open, and brings it forward.
    static func move(_ sessions: [AgentSession], to folder: String, window: WindowContext) {
        let snapshot = window.store.snapshot
        let workspace = snapshot.workspaces.first { snapshot.directory(ofWorkspace: $0.workspaceId) == folder }
        var moved: [String] = []
        var failures: [String] = []
        for session in sessions where session.canMove {
            switch session.move(to: folder, workspaceId: workspace?.workspaceId) {
            case .success(let copy): moved.append(copy.title)
            case .failure(let error): failures.append("\(session.title): \(error.localizedDescription)")
            }
        }
        if let workspace, !moved.isEmpty, workspace.workspaceId != sessions.first?.workspaceId {
            window.focusWorkspace(workspace.workspaceId)
        }
        let place = abbreviateHome(folder)
        if !failures.isEmpty {
            ToastCenter.shared.fail(nil, moved.isEmpty ? "Couldn't move to \(place)" : "Moved some conversations to \(place)",
                                    detail: failures.joined(separator: "\n"))
        } else if moved.count == 1 {
            ToastCenter.shared.info("Moved to \(place)",
                                    detail: "\(moved[0]) carries on there; its transcript was copied into that folder's project.")
        } else if !moved.isEmpty {
            ToastCenter.shared.info("Moved \(moved.count) conversations to \(place)",
                                    detail: "They carry on there; their transcripts were copied into that folder's project.")
        }
    }

    /// Picks a folder and moves `sessions` there.
    static func moveAfterPicking(_ sessions: [AgentSession], from directory: String, window: WindowContext) {
        guard let folder = pickFolder(startingAt: directory) else { return }
        move(sessions, to: folder, window: window)
    }
}
