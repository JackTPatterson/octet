import AppKit
import SwiftUI

/// The details card (⌘⇧B), after T3 Code's thread details: a small glass
/// card over the top right of the terminal with where the tab in front is
/// working and what's going on there. Each row opens the plane that shows
/// more: the folder, the branch, the changes, the pull request, servers and
/// agents.
struct DetailsCard: View {
    @EnvironmentObject private var window: WindowContext
    @ObservedObject var model: StatusBarModel
    @ObservedObject var store: SessionStore
    @ObservedObject var ui: UIState
    @ObservedObject private var ports = PortsWatcher.shared

    var body: some View {
        let workspace = window.focusedWorkspace?.workspaceId
        let serving = workspace.map { ports.ports(inWorkspace: $0, snapshot: store.snapshot) } ?? []
        let agents = workspace.map { store.snapshot.agents(inWorkspace: $0).filter { !$0.isSubagentViewer } } ?? []
        VStack(alignment: .leading, spacing: 2) {
            if let directory = model.directory ?? window.focusedDirectory {
                folderRow(directory)
            }
            if let repo = model.repo {
                DetailsRow(icon: repo.linkedWorktree ? "square.stack.3d.up" : "branch",
                           title: repo.branch ?? (repo.detached ? "Detached HEAD" : "No branch"),
                           detail: repo.linkedWorktree ? "worktree" : repo.operation.isEmpty ? nil : repo.operation.label,
                           help: "Show Git") { show(.git) }
                DetailsRow(icon: "doc.diff", title: "Changes", help: "Show the diff") { show(.diff) } trailing: {
                    if let changes = repo.changes, !changes.isEmpty {
                        DiffStatLabel(added: changes.added, removed: changes.removed)
                    } else {
                        Text("None").font(Theme.captionFont).foregroundStyle(Theme.textTertiary)
                    }
                }
                if let pull = repo.pullRequest {
                    let tone = PullRequestTone(state: pull.state, isDraft: pull.isDraft)
                    DetailsRow(icon: tone.icon, title: "#\(pull.number) \(pull.title)", tint: tone.color,
                               help: "Show the pull request") { show(.pullRequest, number: pull.number) }
                } else {
                    DetailsRow(icon: "pull.request", title: "No pull request", muted: true,
                               help: "Show this branch's pull request") { show(.pullRequest) }
                }
            }
            ForEach(serving, id: \.self) { port in
                DetailsRow(icon: "safari", title: "localhost:\(String(port))", detail: ports.services[port],
                           help: "Open in your browser") {
                    if let url = URL(string: "http://localhost:\(port)") { NSWorkspace.shared.open(url) }
                }
            }
            if !agents.isEmpty {
                let working = agents.filter { $0.agentStatus == .working }.count
                let waiting = agents.filter { $0.agentStatus == .blocked }.count
                DetailsRow(icon: "tool.agent",
                           title: waiting > 0 ? "\(waiting) waiting on you" : working > 0 ? "\(working) working" : "\(agents.count) idle",
                           tint: waiting > 0 ? Color(hex: AgentStateColor.blocked) : nil,
                           help: "Show agents") { window.toggleAgentsBoard() }
            }
        }
        .padding(6)
        .frame(width: 280)
        .octetGlass(cornerRadius: 22, fill: Theme.chrome)
        .onAppear { DebugSnapshot.overlay("details", true) }
        .onDisappear { DebugSnapshot.overlay("details", false) }
    }

    private func folderRow(_ directory: String) -> some View {
        let root = AccountProfiles.projectRoot(of: directory) ?? directory
        return Menu {
            Button("Show Files") { show(.files) }
            Button("New Terminal Here") { show(.terminal) }
            Divider()
            Button("Reveal in Finder") { NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: directory)]) }
            Button("Copy Path") {
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(directory, forType: .string)
            }
        } label: {
            DetailsRowLabel(icon: "folder", title: (root as NSString).lastPathComponent,
                            detail: directory == root ? nil : String(directory.dropFirst(root.count + 1)))
        }
        .menuStyle(.button)
        .buttonStyle(.plain)
        .menuIndicator(.hidden)
        .help(abbreviateHome(directory))
    }

    private func show(_ kind: PlaneKind, number: Int? = nil) {
        MotionPreferences.shared.perform(.sidebar) { ui.showPlane(kind, number: number) }
    }
}

/// A row in the details card: 32pt, an icon, a title, a quiet detail.
private struct DetailsRow<Trailing: View>: View {
    let icon: String
    var tint: Color?
    let title: String
    var detail: String?
    var muted = false
    let help: String
    let action: () -> Void
    @ViewBuilder var trailing: () -> Trailing

    var body: some View {
        Button(action: action) {
            DetailsRowLabel(icon: icon, tint: tint, title: title, detail: detail, muted: muted, trailing: trailing)
        }
        .buttonStyle(.plain)
        .help(help)
    }
}

extension DetailsRow where Trailing == EmptyView {
    init(icon: String, title: String, detail: String? = nil, tint: Color? = nil, muted: Bool = false,
         help: String, action: @escaping () -> Void) {
        self.init(icon: icon, tint: tint, title: title, detail: detail, muted: muted, help: help, action: action,
                  trailing: { EmptyView() })
    }
}

private struct DetailsRowLabel<Trailing: View>: View {
    let icon: String
    var tint: Color?
    let title: String
    var detail: String?
    var muted = false
    @ViewBuilder var trailing: () -> Trailing
    @State private var hovered = false

    var body: some View {
        HStack(spacing: 10) {
            OctetIcon(icon, size: 15)
                .foregroundStyle(tint ?? Theme.textTertiary)
                .frame(width: 18)
            Text(title)
                .font(.system(size: 13, weight: .medium))
                .foregroundStyle(muted ? Theme.textTertiary : Theme.textPrimary.opacity(0.85))
                .lineLimit(1)
                .truncationMode(.tail)
            if let detail {
                Text(detail)
                    .font(Theme.captionFont)
                    .foregroundStyle(Theme.textTertiary)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
            Spacer(minLength: 4)
            trailing()
        }
        .padding(.horizontal, 10)
        .frame(height: 32)
        .background(RoundedRectangle(cornerRadius: Theme.popoverRadius).fill(hovered ? Theme.hover : .clear))
        .contentShape(Rectangle())
        .onHover { hovered = $0 }
    }
}

extension DetailsRowLabel where Trailing == EmptyView {
    init(icon: String, tint: Color? = nil, title: String, detail: String? = nil, muted: Bool = false) {
        self.init(icon: icon, tint: tint, title: title, detail: detail, muted: muted, trailing: { EmptyView() })
    }
}
