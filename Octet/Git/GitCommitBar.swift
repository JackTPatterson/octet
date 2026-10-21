import SwiftUI

/// The commit box, pinned under the changes: a message, the primary git
/// button (Commit, or Commit & Push when that's all it takes; ⌘↩) and a
/// menu for the other way or asking the agent. Why it's unavailable is in
/// its tooltip, not on screen.
struct GitCommitBar: View {
    @ObservedObject var model: GitPanelModel
    let group: GitPanelModel.Group

    private var checkout: AgentGit.Checkout { group.checkout }

    var body: some View {
        let message = Binding(get: { model.drafts[checkout.top] ?? "" }, set: { model.drafts[checkout.top] = $0 })
        let block = GitCommitBlock.block(message: message.wrappedValue, busy: model.busy[checkout.top] != nil,
                                         conflicts: checkout.conflicted.count)
        VStack(alignment: .leading, spacing: 8) {
            OctetTextEditor(placeholder: "Commit message", text: message, minHeight: 44, maxHeight: 64)
            HStack(spacing: 4) {
                GitPrimaryButton(model: model, group: group)
                OctetIconButton(icon: "chevron.down", help: "More commit options", compact: true) { presentMenu(block) }
                Spacer(minLength: 0)
            }
        }
    }

    private func presentMenu(_ block: GitCommitBlock?) {
        var items: [OctetMenuItem] = []
        let primary = GitPrimaryButton(model: model, group: group).action
        if primary.kind == .commitAndPush {
            items.append(.action("Commit Only", icon: "check", enabled: block == nil,
                                 help: block?.reason ?? "Commit without pushing") { model.commit(checkout) })
        } else if checkout.branch.name != nil {
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
