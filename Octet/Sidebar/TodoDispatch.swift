import AppKit
import SwiftUI

/// Who a todo can go to, and the sending: an Octet conversation gets it as
/// a message, a terminal agent as typed input, and "Start a conversation"
/// opens a new one with it. Whoever gets it is asked to tick it off in its
/// list, and the item is marked under way with who has it.
@MainActor
enum TodoDispatch {
    struct Target: Identifiable, Equatable {
        enum Kind: Equatable {
            case conversation(String)
            case pane(String)
        }

        let kind: Kind
        /// The brand id, for the logo: claude, codex…
        let agent: String?
        let name: String

        var id: String {
            switch kind {
            case .conversation(let id): "conversation:" + id
            case .pane(let id): "pane:" + id
            }
        }
    }

    /// Every conversation in the workspace in front, the one showing first,
    /// then the terminal agents in its tabs, the tab in front first.
    static func targets(in window: WindowContext) -> [Target] {
        let workspaceId = window.focusedWorkspace?.workspaceId
        let showing = AgentCenter.shared.active(in: workspaceId)?.id
        let all = AgentCenter.shared.sessions(in: workspaceId)
        let sessions = all.filter { $0.id == showing } + all.filter { $0.id != showing }
        var targets = sessions.map { session in
            Target(kind: .conversation(session.id), agent: session.engine.agent,
                   name: sessions.count > 1 ? "\(session.engine.displayName) · \(session.title)" : session.engine.displayName)
        }
        let tab = window.displayedFocusedTabId
        let here = window.store.snapshot.agents
            .filter { $0.workspaceId == workspaceId && $0.agent != nil && !$0.isSubagentViewer }
        let agents = here.filter { $0.tabId == tab } + here.filter { $0.tabId != tab }
        targets += agents.map { agent in
            Target(kind: .pane(agent.paneId), agent: AgentBrand.forAgent(agent.agent)?.id ?? agent.agent,
                   name: AgentBrand.forAgent(agent.agent)?.displayName ?? agent.agent ?? "Agent")
        }
        return targets
    }

    /// Where ⌘Return and the row's arrow send: the conversation showing, else
    /// the agent in the tab in front, else any.
    static func inFront(_ window: WindowContext) -> Target? {
        targets(in: window).first
    }

    /// The agents a new conversation can be started with, that are installed.
    static var engines: [AgentSession.Engine] {
        let installed = Set(AgentDiscoveryStore.shared.agents.filter { $0.executablePath != nil }.map(\.id))
        let all: [AgentSession.Engine] = [.claude, .codex, .opencode]
        let found = all.filter { installed.contains($0.agent) }
        return found.isEmpty ? [.claude] : found
    }

    /// Sends `item` to `target`, and marks it under way with whom.
    static func send(_ item: ProjectTodoList.Item, in kind: TodoModel.ListKind, to target: Target,
                     model: TodoModel, window: WindowContext) {
        let prompt = prompt(for: item, in: kind, model: model)
        switch target.kind {
        case .conversation(let id):
            guard let session = AgentCenter.shared.sessions.first(where: { $0.id == id }) else {
                ToastCenter.shared.info("That conversation has closed")
                return
            }
            session.send(prompt)
        case .pane(let paneId):
            window.store.broadcast(prompt, to: [Broadcast.Target(paneId: paneId, name: target.name, isAgent: true)])
        }
        handedOff(item, in: kind, agent: target.agent, name: target.name,
                  conversationId: { if case .conversation(let id) = target.kind { id } else { nil } }(), model: model)
    }

    /// Opens a new conversation in the workspace and sends it the item.
    static func start(_ item: ProjectTodoList.Item, in kind: TodoModel.ListKind, engine: AgentSession.Engine,
                      model: TodoModel, window: WindowContext) {
        guard let workspaceId = window.focusedWorkspace?.workspaceId else { return }
        let cwd = window.store.snapshot.directory(ofWorkspace: workspaceId) ?? model.projectRoot ?? NSHomeDirectory()
        let session = AgentCenter.shared.newConversation(workspaceId: workspaceId, cwd: cwd, engine: engine)
        session.send(prompt(for: item, in: kind, model: model))
        handedOff(item, in: kind, agent: engine.agent, name: engine.displayName, conversationId: session.id, model: model)
    }

    /// The prompt, naming the list so the agent can tick the item: the file
    /// name for the project's, the whole path for yours (it's in .git).
    static func prompt(for item: ProjectTodoList.Item, in kind: TodoModel.ListKind, model: TodoModel) -> String {
        let path = model.path(of: kind) ?? ProjectTodos.fileNames[0]
        return ProjectTodos.prompt(for: item, fileName: kind == .mine ? path : (path as NSString).lastPathComponent)
    }

    private static func handedOff(_ item: ProjectTodoList.Item, in kind: TodoModel.ListKind, agent: String?, name: String,
                                  conversationId: String?, model: TodoModel) {
        model.updateLink(item) {
            $0.agent = agent
            $0.agentName = AgentBrand.forAgent(agent)?.displayName ?? name
            $0.conversationId = conversationId
        }
        if item.status == .pending { model.set(item, in: kind, to: .inProgress) }
        ToastCenter.shared.info("Sent to \(name)", detail: item.text)
    }

    /// Brings the conversation or the pane a plan or item belongs to to front.
    static func open(conversationId: String?, paneId: String?, tabId: String?, window: WindowContext) {
        if let conversationId, AgentCenter.shared.sessions.contains(where: { $0.id == conversationId }) {
            AgentCenter.shared.setActive(conversationId, in: window.focusedWorkspace?.workspaceId)
        } else if let paneId {
            AgentCenter.shared.setActive(nil, in: window.focusedWorkspace?.workspaceId)
            if let tabId, tabId != window.displayedFocusedTabId { window.focusTab(tabId) }
            window.focusAgent(paneId: paneId)
        }
    }
}
