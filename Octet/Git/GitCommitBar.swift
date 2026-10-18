import SwiftUI

/// The commit box, pinned under the changes: a message, Commit (⌘↩) and a
/// menu for Commit & Push or asking the agent. Why Commit is unavailable is
/// in its tooltip, not on screen.
struct GitCommitBar: View {
    @ObservedObject var model: GitPanelModel
    let group: GitPanelModel.Group

    private var checkout: AgentGit.Checkout { group.checkout }

    var body: some View {
        let plan = GitRemote.commitPlan(files: checkout.files)
        let message = Binding(get: { model.drafts[checkout.top] ?? "" }, set: { model.drafts[checkout.top] = $0 })
        let block = GitCommitBlock.block(message: message.wrappedValue, busy: model.busy[checkout.top] != nil,
                                         conflicts: checkout.conflicted.count)
        VStack(alignment: .leading, spacing: 8) {
            OctetTextEditor(placeholder: "Commit message", text: message, minHeight: 44, maxHeight: 64)
            HStack(spacing: 4) {
                OctetButton(title: plan.stageAll ? "Commit All" : "Commit", kind: .primary, compact: true) {
                    model.commit(checkout)
                }
                .disabled(block != nil)
                .keyboardShortcut(.return, modifiers: .command)
                .help(block?.reason ?? (plan.stageAll
                      ? "Nothing is staged, so this commits all \(Recap.count(plan.count, "change")). (⌘↩)"
                      : "Commits the \(Recap.count(plan.count, "staged file")). (⌘↩)"))
                OctetIconButton(icon: "chevron.down", help: "More commit options", compact: true) { presentMenu(block) }
                Spacer(minLength: 0)
            }
        }
    }

    private func presentMenu(_ block: GitCommitBlock?) {
        var items: [OctetMenuItem] = []
        if checkout.branch.name != nil {
            items.append(.action("Commit & Push", icon: "arrow.up", enabled: block == nil,
                                 help: block?.reason ?? "Commit, then push the branch") { model.commit(checkout, push: true) })
        }
        if group.workers.contains(where: \.takesPrompts) {
            items.append(.action("Ask Agent to Write & Commit", icon: "sparkles",
                                 help: "Ask the agent to write the message and commit") { model.handoff(.commit, in: group) })
        }
        OctetContextMenu.present(items)
    }
}
