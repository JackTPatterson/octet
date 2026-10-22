import AppKit

/// Moving conversations to another folder from the UI: the folder picker,
/// the move itself for one conversation or a workspace's, and the toast
/// that says how it went. See `AgentSession.move(to:)`.
@MainActor
enum ConversationMover {
    /// Asks for the folder (one typed that isn't there yet can be made);
    /// nothing happens when cancelled.
    static func pickFolder(startingAt directory: String, window: WindowContext, then picked: @escaping (String) -> Void) {
        PathPickerCenter.shared.pick("Move the Conversation",
                                     message: "Choose the folder to carry on in. Claude Code resumes the conversation there.",
                                     prompt: "Move", start: directory, canCreateFolder: true, in: window.nsWindow) { urls in
            guard let url = urls.first else { return }
            picked(url.standardizedFileURL.path)
        }
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
        pickFolder(startingAt: directory, window: window) { folder in
            move(sessions, to: folder, window: window)
        }
    }
}
