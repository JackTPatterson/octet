import SwiftUI

/// One checkout's slim header: who is in it, the branch and how it stands,
/// the single sync action that applies now, and a menu for everything else.
struct GitHeader: View {
    @ObservedObject var model: GitPanelModel
    let group: GitPanelModel.Group

    private var checkout: AgentGit.Checkout { group.checkout }

    var body: some View {
        let busy = model.busy[checkout.top]
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 6) {
                if !group.workers.isEmpty {
                    WorkerMarks(workers: group.workers) { model.show($0) }
                        .help(Self.workersLabel(group))
                }
                BranchPickerChip(top: checkout.top, branch: checkout.branch.name, changed: { model.refresh() })
                    .layoutPriority(1)
                BaseStanding(checkout: checkout)
                Spacer(minLength: 4)
                // With changes, the primary button sits in the commit box.
                if checkout.files.isEmpty {
                    GitPrimaryButton(model: model, group: group)
                } else if let busy {
                    LoadingLine(width: 12).accessibilityHidden(true)
                    Text(busy).font(Theme.captionFont).foregroundStyle(Theme.textTertiary).lineLimit(1)
                }
                OctetIconButton(icon: "ellipsis", help: "More git actions", compact: true) { presentMenu() }
                    .disabled(busy != nil)
            }
            if checkout.isLinkedWorktree || !checkout.operation.isEmpty {
                HStack(spacing: 8) {
                    if checkout.isLinkedWorktree {
                        Text("worktree")
                            .font(Theme.captionFont)
                            .foregroundStyle(Theme.textTertiary)
                            .padding(.horizontal, 5)
                            .frame(height: 15)
                            .background(Capsule().fill(Theme.card))
                    }
                    if !checkout.operation.isEmpty {
                        HStack(spacing: 5) {
                            Image(systemName: "exclamationmark.triangle.fill").font(.system(size: 9.5))
                                .accessibilityHidden(true)
                            Text(checkout.operation.label).font(Theme.captionFont.weight(.medium))
                        }
                        .foregroundStyle(Theme.danger)
                        .accessibilityElement(children: .combine)
                    }
                }
            }
        }
    }

    static func workersLabel(_ group: GitPanelModel.Group) -> String {
        let leads = group.workers.filter { !$0.isSubagent }
        let subagents = group.workers.count - leads.count
        let lead = leads.first?.name ?? group.workers.first?.name ?? "Here"
        switch subagents {
        case 0: return leads.count > 1 ? "\(lead) + \(leads.count - 1)" : lead
        case 1: return "\(lead) · 1 subagent"
        default: return "\(lead) · \(subagents) subagents"
        }
    }

    private func presentMenu() {
        let branch = checkout.branch
        var items: [OctetMenuItem] = [
            .action("Fetch", icon: "arrow.clockwise", help: "Fetch from every remote") { model.fetch(checkout) },
        ]
        if branch.upstream != nil {
            items.append(.action(branch.behind > 0 ? "Pull \(branch.behind)" : "Pull", icon: "arrow.down",
                                 help: "Pull from \(branch.upstream ?? "upstream"), only when it fast-forwards") { model.pull(checkout) })
            items.append(.action(branch.ahead > 0 ? "Push \(branch.ahead)" : "Push", icon: "arrow.up",
                                 help: "Push to \(branch.upstream ?? "upstream")") { model.push(checkout) })
        } else if branch.name != nil {
            items.append(.action("Publish Branch", icon: "arrow.up",
                                 help: "Push this branch to the remote and track it") { model.push(checkout) })
        }
        if branch.name != nil, !checkout.onBase {
            items.append(.action("Open Pull Request", icon: "arrow.triangle.branch",
                                 help: "Open a pull request for this branch on its host") { model.openPullRequest(checkout) })
        }
        let groups = GitChangeGroups(files: checkout.files)
        if !groups.changes.isEmpty || !groups.untracked.isEmpty || !groups.staged.isEmpty { items.append(.divider) }
        if !groups.changes.isEmpty || !groups.untracked.isEmpty {
            items.append(.action("Stage All", icon: "plus", help: "Stage every change, untracked files too") { model.stageAll(checkout) })
        }
        if !groups.staged.isEmpty {
            items.append(.action("Unstage All", icon: "minus", help: "Keep the changes, staged none") { model.unstageAll(checkout) })
        }
        items.append(.divider)
        items.append(.action("Review Changes", icon: "doc.text.magnifyingglass", shortcut: "⇧⌘R") { model.review(checkout.top) })
        items.append(.action("Copy Branch Name", icon: "doc.on.doc", enabled: branch.name != nil) {
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(branch.name ?? "", forType: .string)
        })
        items.append(.action("Copy Path", icon: "doc.on.doc") {
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(checkout.top, forType: .string)
        })
        OctetContextMenu.present(items)
    }
}

/// Ahead of and behind the default branch, compactly.
struct BaseStanding: View {
    let checkout: AgentGit.Checkout

    var body: some View {
        if let base = checkout.base, !checkout.onBase {
            HStack(spacing: 4) {
                if checkout.aheadOfBase > 0 { count("arrow.up", checkout.aheadOfBase) }
                if checkout.behindBase > 0 { count("arrow.down", checkout.behindBase) }
                if checkout.aheadOfBase == 0 && checkout.behindBase == 0 {
                    Text("even").font(Theme.captionFont).foregroundStyle(Theme.textTertiary)
                }
            }
            .help("\(checkout.aheadOfBase) ahead of \(base), \(checkout.behindBase) behind")
            .accessibilityElement(children: .ignore)
            .accessibilityLabel("\(checkout.aheadOfBase) ahead of \(base), \(checkout.behindBase) behind")
        } else if checkout.branch.ahead > 0 || checkout.branch.behind > 0 {
            HStack(spacing: 4) {
                if checkout.branch.ahead > 0 { count("arrow.up", checkout.branch.ahead) }
                if checkout.branch.behind > 0 { count("arrow.down", checkout.branch.behind) }
            }
            .help("Against \(checkout.branch.upstream ?? "its upstream")")
            .accessibilityElement(children: .ignore)
            .accessibilityLabel("\(checkout.branch.ahead) ahead of \(checkout.branch.upstream ?? "its upstream"), \(checkout.branch.behind) behind")
        }
    }

    private func count(_ icon: String, _ value: Int) -> some View {
        HStack(spacing: 1) {
            OctetIcon(icon, size: 9)
            Text("\(value)").font(Theme.captionFont.monospacedDigit())
        }
        .foregroundStyle(Theme.textSecondary)
    }
}
