import Foundation

/// One prompt sent to several panes at once, like iTerm2's broadcast input
/// or tmux's synchronize-panes, but aimed at agents: the same task to every
/// agent in a project, or the same line to every shell in a split.
enum Broadcast {
    enum Scope: String, CaseIterable {
        /// Every pane in the tab in front, shells included.
        case tab
        /// Every agent in the workspace in front.
        case workspace
        /// Every agent in every workspace.
        case everywhere
    }

    struct Target: Equatable {
        let paneId: String
        /// What it's called in the confirmation: the agent's name, or the tab's.
        let name: String
        /// Agents take the text as a prompt; shells take it as a typed line.
        let isAgent: Bool
    }

    /// Who receives a broadcast. A subagent's viewer isn't a place to type,
    /// so it's never a target; neither is a workspace or tab that isn't there.
    static func targets(_ scope: Scope, in snapshot: EngineSnapshot,
                        workspaceId: String?, tabId: String?) -> [Target] {
        let agentsByPane = Dictionary(snapshot.agents.map { ($0.paneId, $0) }, uniquingKeysWith: { first, _ in first })
        let viewers = Set(snapshot.agents.filter(\.isSubagentViewer).map(\.paneId))
        let tabs = Dictionary(snapshot.tabs.map { ($0.tabId, $0) }, uniquingKeysWith: { first, _ in first })
        let workspaceOrder = Dictionary(snapshot.workspaces.map { ($0.workspaceId, $0.number) },
                                        uniquingKeysWith: { first, _ in first })

        func target(_ paneId: String, tabId: String?) -> Target {
            if let agent = agentsByPane[paneId], agent.agent != nil {
                let brand = AgentBrand.forAgent(agent.agent)?.displayName ?? agent.displayAgent ?? agent.agent ?? "Agent"
                let tab = (agent.tabId ?? tabId).flatMap { tabs[$0] }.map { TabAutoName.display(label: $0.label, number: $0.number) }
                return Target(paneId: paneId, name: tab.map { "\(brand) in \($0)" } ?? brand, isAgent: true)
            }
            let tab = tabId.flatMap { tabs[$0] }.map { TabAutoName.display(label: $0.label, number: $0.number) }
            return Target(paneId: paneId, name: tab ?? "Terminal", isAgent: false)
        }

        switch scope {
        case .tab:
            guard let tabId else { return [] }
            return snapshot.panes
                .filter { $0.tabId == tabId && !viewers.contains($0.paneId) }
                .map { target($0.paneId, tabId: $0.tabId) }
        case .workspace, .everywhere:
            if scope == .workspace, workspaceId == nil { return [] }
            return snapshot.agents
                .filter { $0.agent != nil && !$0.isSubagentViewer }
                .filter { scope == .everywhere || $0.workspaceId == workspaceId }
                .sorted {
                    let left = (workspaceOrder[$0.workspaceId ?? ""] ?? .max, $0.tabId.flatMap { tabs[$0]?.number } ?? .max)
                    let right = (workspaceOrder[$1.workspaceId ?? ""] ?? .max, $1.tabId.flatMap { tabs[$0]?.number } ?? .max)
                    return left < right
                }
                .map { target($0.paneId, tabId: $0.tabId) }
        }
    }

    /// Sends `text` to each target through `call` (a socket request) and
    /// returns the names of those it couldn't reach. An agent gets it as a
    /// prompt, typed and submitted in one step; if the session server
    /// doesn't know the agent, or for a shell, it's typed with a Return.
    /// Targets are sent to concurrently, so one slow pane can't hold up the rest.
    static func deliver(_ text: String, to targets: [Target],
                        call: @escaping (String, [String: Any]) throws -> Void) -> [String] {
        let lock = NSLock()
        var failed: [String] = []
        DispatchQueue.concurrentPerform(iterations: targets.count) { index in
            let target = targets[index]
            if target.isAgent, (try? call("agent.prompt", ["target": target.paneId, "text": text])) != nil { return }
            if (try? call("pane.send_text", ["pane_id": target.paneId, "text": text + "\r"])) != nil { return }
            lock.lock(); failed.append(target.name); lock.unlock()
        }
        return failed.sorted()
    }

    /// "Claude Code in api and Codex in web", or "3 agents" once a list stops
    /// being readable.
    static func summary(_ targets: [Target]) -> String {
        switch targets.count {
        case 0: return "nothing"
        case 1: return targets[0].name
        case 2: return "\(targets[0].name) and \(targets[1].name)"
        default:
            let noun = targets.allSatisfy(\.isAgent) ? "agents" : "panes"
            return "\(targets.count) \(noun)"
        }
    }
}
