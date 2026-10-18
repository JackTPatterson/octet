import SwiftUI

// The small pieces the git panel's sections share: line counts, the agents'
// marks, and the filter that narrows changes to one agent's edits.

struct LineCounts: View {
    let added: Int?
    let removed: Int?

    var body: some View {
        DiffStatLabel(added: added ?? 0, removed: removed ?? 0)
    }
}

/// The agents' marks, overlapping; a click brings that agent's tab forward.
struct WorkerMarks: View {
    let workers: [GitPanelModel.Worker]
    var size: CGFloat = 12
    var limit = 4
    /// Clicking a mark shows that worker's tab; without it the marks only label.
    var show: ((GitPanelModel.Worker) -> Void)?

    var body: some View {
        HStack(spacing: -3) {
            ForEach(workers.prefix(limit)) { worker in
                if let show {
                    Button { show(worker) } label: { WorkerMark(worker: worker, size: size) }
                        .buttonStyle(.plain)
                        .help("\(worker.name) — show its tab")
                        .accessibilityLabel("Show \(worker.name)'s tab")
                } else {
                    WorkerMark(worker: worker, size: size)
                }
            }
        }
    }
}

/// One agent's mark: its logo, or a subagent's icon in its vendor's colour.
struct WorkerMark: View {
    let worker: GitPanelModel.Worker
    var size: CGFloat = 12

    var body: some View {
        Group {
            if let brand = AgentBrand.forAgent(worker.agent) {
                if worker.isSubagent {
                    OctetIcon("tool.agent", size: size - 1)
                        .foregroundStyle(brand.hueHex.map { Color(hex: $0) } ?? Theme.textSecondary)
                } else {
                    AgentLogo(brand: brand, size: size)
                }
            } else {
                OctetIcon("terminal", size: size - 1).foregroundStyle(Theme.textTertiary)
            }
        }
        .frame(width: size + 4, height: size + 4)
        .background(Circle().fill(Theme.sidebar))
    }
}

enum EditorFilter: Hashable {
    case worker(String)
    /// Changed outside any agent's edit tool: a shell command, or by hand.
    case unattributed
}

/// Narrows the changes to one agent's edits, with how many each made.
struct EditorFilterRow: View {
    let editors: [GitPanelModel.Worker]
    let group: GitPanelModel.Group
    @Binding var filter: EditorFilter?

    var body: some View {
        let files = group.checkout.files
        let unattributed = files.filter { group.editors[$0.path] == nil }.count
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 4) {
                chip(nil, count: files.count) { Text("All") }
                ForEach(editors) { editor in
                    let count = files.filter { group.editors[$0.path]?.contains { $0.paneId == editor.paneId } == true }.count
                    chip(.worker(editor.paneId), count: count) {
                        HStack(spacing: 4) {
                            WorkerMark(worker: editor, size: 10)
                            Text(editor.name).lineLimit(1)
                        }
                    }
                    .help("Only the files \(editor.name) edited")
                }
                if unattributed > 0 {
                    chip(.unattributed, count: unattributed) { Text("Other") }
                        .help("Files no agent's edit tool changed: from a shell command, or by hand")
                }
            }
        }
    }

    private func chip<Label: View>(_ value: EditorFilter?, count: Int, @ViewBuilder label: () -> Label) -> some View {
        let selected = filter == value
        return Button { filter = selected ? nil : value } label: {
            HStack(spacing: 4) {
                label()
                Text("\(count)").monospacedDigit().foregroundStyle(Theme.textTertiary)
            }
            .font(Theme.captionFont.weight(selected ? .medium : .regular))
            .foregroundStyle(selected ? Theme.textPrimary : Theme.textSecondary)
            .padding(.horizontal, 6)
            .frame(height: 18)
            .background(Capsule().fill(selected ? Theme.cardSelected : Theme.card))
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(selected ? .isSelected : [])
    }
}
