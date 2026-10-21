import SwiftUI

/// The checkout's one primary git button: its label follows the state
/// (`GitPrimaryAction`), it shows the work in progress inside itself, and
/// when it can't run its reason is in the tooltip, or beside it for a
/// diverged branch, which needs the person to act.
struct GitPrimaryButton: View {
    @ObservedObject var model: GitPanelModel
    let group: GitPanelModel.Group

    private var checkout: AgentGit.Checkout { group.checkout }

    var action: GitPrimaryAction {
        let message = model.drafts[checkout.top] ?? ""
        return GitPrimaryAction.resolve(
            branch: checkout.branch, changes: checkout.files.count,
            commitBlock: GitCommitBlock.block(message: message, busy: false, conflicts: checkout.conflicted.count),
            // A repository with no remote says so when the push is tried.
            hasRemote: true, onBase: checkout.onBase, aheadOfBase: checkout.aheadOfBase)
    }

    var body: some View {
        let action = self.action
        if let busy = model.busy[checkout.top] {
            HStack(spacing: 6) {
                LoadingLine(width: 12, color: Theme.onAccent)
                Text(busy).font(Theme.uiFontMedium).lineLimit(1)
            }
            .foregroundStyle(Theme.onAccent)
            .padding(.horizontal, 8)
            .frame(height: 24)
            .background(RoundedRectangle(cornerRadius: Theme.controlRadius).fill(Theme.accent.opacity(0.7)))
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(busy)
            .accessibilityAddTraits(.updatesFrequently)
        } else {
            HStack(spacing: 6) {
                if action.kind == .sync, let reason = action.blocked {
                    Text("Diverged")
                        .font(Theme.captionFont.weight(.medium))
                        .foregroundStyle(Theme.warning)
                        .help(reason)
                }
                OctetButton(title: action.title, icon: action.icon, kind: .primary, compact: true) { perform(action) }
                    .disabled(!action.enabled)
                    .keyboardShortcut(action.kind == .commit || action.kind == .commitAndPush
                                      ? KeyboardShortcut(.return, modifiers: .command) : nil)
                    .help(action.blocked ?? help(action))
                    .accessibilityHint(action.blocked ?? help(action))
            }
        }
    }

    private func perform(_ action: GitPrimaryAction) {
        guard action.enabled else { return }
        switch action.kind {
        case .commit: model.commit(checkout)
        case .commitAndPush: model.commit(checkout, push: true)
        case .push, .publish: model.push(checkout)
        case .pull: model.pull(checkout)
        case .pushAndCreatePullRequest: model.openPullRequest(checkout)
        case .sync: break
        }
    }

    private func help(_ action: GitPrimaryAction) -> String {
        let upstream = checkout.branch.upstream ?? "upstream"
        let plan = GitRemote.commitPlan(files: checkout.files)
        let what = plan.stageAll ? "all \(Recap.count(plan.count, "change"))" : "the \(Recap.count(plan.count, "staged file"))"
        switch action.kind {
        case .commit: return "Commit \(what) (⌘↩)"
        case .commitAndPush: return "Commit \(what), then push to \(upstream) (⌘↩)"
        case .push: return "Push \(Recap.count(checkout.branch.ahead, "commit")) to \(upstream)"
        case .pull: return "Pull \(Recap.count(checkout.branch.behind, "commit")) from \(upstream), only when it fast-forwards"
        case .publish: return "Push this branch to the remote and track it"
        case .pushAndCreatePullRequest: return "Publish this branch, then open a pull request for it"
        case .sync: return ""
        }
    }
}
