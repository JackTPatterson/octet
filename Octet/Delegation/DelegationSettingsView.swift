import SwiftUI

/// Settings › Plugins › Agent Delegation, while it's on: when to ask, and
/// the delegations running now.
struct DelegationSettingsGroup: View {
    @ObservedObject var settings: SettingsStore
    @ObservedObject private var center = DelegationCenter.shared

    var body: some View {
        SettingsGroup(title: "Agent Delegation") {
            SettingsRow(
                title: "Ask before delegating",
                detail: "A review only reads, so it can go ahead on its own. A task changes files, in a worktree of its own."
            ) {
                Picker("Ask before delegating", selection: $settings.values.delegationApproval) {
                    ForEach(DelegationCenter.Approval.allCases) { Text($0.title).tag($0.rawValue) }
                }
                .labelsHidden()
                .frame(width: 250)
            }
            SettingsDivider()
            SettingsRow(
                title: "Tools in your agents",
                detail: "Claude Code and Codex get delegate_to_agent, wait_for_delegate and list_delegates through the octet-delegate MCP server. A delegate can't delegate again."
            ) {
                Button("Add Again") { center.configureAgents(install: true) }
            }
            let running = center.delegations.values.filter { $0.result == nil }.sorted { $0.started > $1.started }
            if !running.isEmpty {
                SettingsDivider()
                ForEach(running) { delegation in
                    SettingsRow(title: "\(delegation.agent) · \(delegation.mode == .review ? "reviewing" : "working") for \(delegation.caller)",
                                detail: delegation.summary) { EmptyView() }
                }
            }
        }
    }
}
