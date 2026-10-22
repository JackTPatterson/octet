import SwiftUI

/// Where the keyboard is in the Todos tab.
enum TodoFocus: Hashable {
    case add
    case item(TodoModel.ListKind, String)
    case step(String, String)
}

/// The Todos tab: one place for what's left to do in this workspace. What
/// the agents are doing now, live and read-only; your own todos for this
/// checkout; the project's `TODO.md`; and what the workspace is linked to.
/// Every row can become an agent's work in one action, and none of it needs
/// a server.
struct TodoPanel: View {
    @ObservedObject var model: TodoModel
    @ObservedObject var ui: UIState
    /// The panel is in front, not just built behind another plane.
    var visible = true
    @EnvironmentObject private var window: WindowContext
    @ObservedObject private var motion = MotionPreferences.shared
    @FocusState private var focus: TodoFocus?

    var body: some View {
        let summary = self.summary
        let loading = PlaneLoadingPreview.shows("todos") || PlaneLoadingPreview.shows("overview")
            || (model.sections.isEmpty && model.mine == nil && model.project == nil
                && ((model.loading && !model.loaded) || model.listsLoading))
        SidePanelSectionView(.todos, label: summary.text, labelColor: summary.isComplete ? Theme.success : nil,
                             trailing: { TodoFilterMenu(model: model) }) {
            if loading {
                OverviewTodoSkeleton()
            } else {
                content(summary)
            }
        }
        .accessibilityValue(summary.spoken)
        .animation(motion.animation(.sidebar, .smooth(duration: 0.2)), value: model.sections)
        .onAppear { model.refresh() }
        .onChange(of: summary) { _, value in showBadge(value) }
        .onAppear { showBadge(summary) }
        .onKeyPress(phases: .down) { press in handleKey(press) }
    }

    @ViewBuilder
    private func content(_ summary: TodoSummary) -> some View {
        let filter = model.filter
        let nothing = model.sections.isEmpty && (model.mine?.items.isEmpty ?? true) && model.project == nil
            && model.issue == nil && model.waits.isEmpty && model.proposed == nil
        VStack(alignment: .leading, spacing: Theme.Space.lg) {
            if nothing {
                VStack(alignment: .leading, spacing: Theme.Space.xxs) {
                    Text("Nothing to do here yet.").font(Theme.Text.body).foregroundStyle(Theme.textSecondary)
                    Text("Add a todo, or start an agent; its plan shows up here.")
                        .font(Theme.Text.caption).foregroundStyle(Theme.textTertiary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                .accessibilityElement(children: .combine)
                // Brought to the front, it's ready for a todo. Not merely on
                // appearing: the plane is built behind others at launch, and
                // took the keys from the terminal.
                .onChange(of: visible) { _, now in if now { focus = .add } }
            } else if summary.isComplete {
                Text("All caught up · \(summary.done) of \(summary.total) done")
                    .font(Theme.Text.caption.monospacedDigit())
                    .foregroundStyle(Theme.success)
            }
            if summary.total > 0 { TodoSummaryBar(summary: summary) }
            if filter.shows(.agents) {
                if let proposed = model.proposed { ProposedPlanCard(proposed: proposed, model: model) }
                ForEach(model.sections) { section in
                    TodoPlanView(section: section, showsTitle: model.sections.count > 1, model: model, focus: $focus)
                }
            }
            if filter.shows(.mine) {
                TodoListSection(kind: .mine, model: model, focus: $focus)
            }
            if filter.shows(.project), model.projectRoot != nil {
                TodoListSection(kind: .project, model: model, focus: $focus)
            }
            if filter.shows(.linked), model.issue != nil || !model.waits.isEmpty {
                TodoLinkedSection(model: model)
            }
        }
    }

    private var summary: TodoSummary {
        let plans = model.filter.shows(.agents) ? model.sections.filter(\.running).map(\.todos) : []
        var lists: [[AgentTodo.Status]] = []
        if model.filter.shows(.mine) { lists.append(model.mine?.items.map(\.status) ?? []) }
        if model.filter.shows(.project) { lists.append(model.project?.items.map(\.status) ?? []) }
        return TodoSummary(runningPlans: plans, lists: lists)
    }

    /// "3/7" on the tab's chip in the strip.
    private func showBadge(_ summary: TodoSummary) {
        guard let plane = ui.planes.first(where: { $0.kind == .todos }) else { return }
        let badge = summary.total == 0 ? nil
            : PlaneBadge(title: summary.badge, tint: summary.isComplete ? Theme.success : nil, help: summary.spoken)
        if ui.planeBadges[plane.id] != badge { ui.planeBadges[plane.id] = badge }
    }

    // MARK: - Keyboard

    /// Every row the keyboard walks, top to bottom.
    private var order: [TodoFocus] {
        var all: [TodoFocus] = []
        if model.filter.shows(.agents) {
            for section in model.sections where section.running {
                all += section.todos.filter { $0.status != .completed }.map { .step(section.id, $0.id) }
            }
        }
        if model.filter.shows(.mine) {
            all.append(.add)
            all += visibleItems(.mine).map { .item(.mine, $0.id) }
        }
        if model.filter.shows(.project) { all += visibleItems(.project).map { .item(.project, $0.id) } }
        return all
    }

    private func visibleItems(_ kind: TodoModel.ListKind) -> [ProjectTodoList.Item] {
        guard let list = model.list(kind) else { return [] }
        let open = list.items.filter { $0.status != .completed || model.lingering.contains($0.id) }
        return ProjectTodoGrouping.groups(open).flatMap(\.items)
    }

    private func focusedItem() -> (TodoModel.ListKind, ProjectTodoList.Item)? {
        guard case .item(let kind, let id) = focus, let item = model.list(kind)?.items.first(where: { $0.id == id }) else { return nil }
        return (kind, item)
    }

    private func handleKey(_ press: KeyPress) -> KeyPress.Result {
        guard let focus, focus != .add else { return .ignored }
        let order = self.order
        let index = order.firstIndex(of: focus)
        let command = press.modifiers.contains(.command), option = press.modifiers.contains(.option)
        switch press.key {
        case .upArrow where command && option, .downArrow where command && option:
            guard let (kind, item) = focusedItem() else { return .ignored }
            model.move(item, in: kind, by: press.key == .upArrow ? -1 : 1)
            return .handled
        case .upArrow, .downArrow:
            guard let index else { self.focus = order.first; return .handled }
            let next = index + (press.key == .upArrow ? -1 : 1)
            if order.indices.contains(next) { self.focus = order[next] }
            return .handled
        case .space:
            guard let (kind, item) = focusedItem() else { return .ignored }
            model.set(item, in: kind, to: option ? .inProgress : item.status == .completed ? .pending : .completed)
            return .handled
        case .return where command:
            guard let (kind, item) = focusedItem(), let target = TodoDispatch.inFront(window) else { return .ignored }
            TodoDispatch.send(item, in: kind, to: target, model: model, window: window)
            return .handled
        case .return:
            guard focusedItem() != nil else { return .ignored }
            TodoRowEditing.shared.editing = self.focus
            return .handled
        case .delete where command:
            guard let (kind, item) = focusedItem() else { return .ignored }
            moveFocus(awayFrom: focus, in: order)
            model.delete(item, in: kind)
            return .handled
        case .escape:
            self.focus = nil
            OctetTerminalRuntime.focusTerminal()
            return .handled
        default:
            if press.characters == "n", press.modifiers.isEmpty {
                self.focus = .add
                return .handled
            }
            return .ignored
        }
    }

    private func moveFocus(awayFrom current: TodoFocus, in order: [TodoFocus]) {
        guard let index = order.firstIndex(of: current) else { return }
        focus = order.indices.contains(index + 1) ? order[index + 1] : index > 0 ? order[index - 1] : nil
    }
}

/// Which row is being reworded: shared so the panel's Return key and a
/// row's double-click start the same edit.
@MainActor
final class TodoRowEditing: ObservableObject {
    static let shared = TodoRowEditing()
    @Published var editing: TodoFocus?
}

/// The filter at the header's right: show finished items or not, and which
/// sections to show. Kept per project.
private struct TodoFilterMenu: View {
    @ObservedObject var model: TodoModel

    var body: some View {
        OctetMenuButton({ items }) {
            OctetIcon("line.3.horizontal.decrease", size: 13)
                .foregroundStyle(model.filter == TodoModel.Filter() ? Theme.textTertiary : Theme.accent)
                .frame(width: 22, height: 22)
                .contentShape(Rectangle())
        }
        .fixedSize()
        .help("Filter todos")
        .accessibilityLabel("Filter todos")
    }

    private var items: [OctetMenuItem] {
        var items: [OctetMenuItem] = [
            .action("Show Done", icon: model.filter.showDone ? "checkmark" : nil) { model.filter.showDone.toggle() },
            .divider,
            .header("Sources"),
        ]
        for source in TodoModel.Source.allCases {
            let shown = model.filter.shows(source)
            items.append(.action(source.title, icon: shown ? "checkmark" : nil) {
                if shown { model.filter.hidden.insert(source.rawValue) } else { model.filter.hidden.remove(source.rawValue) }
            })
        }
        return items
    }
}

/// How far everything has got: a segment a task when there are a few,
/// after T3 Code's task badge, else one slim bar.
private struct TodoSummaryBar: View {
    let summary: TodoSummary

    var body: some View {
        Group {
            if summary.segmented {
                HStack(spacing: Theme.Space.xxs) {
                    ForEach(Array(summary.statuses.enumerated()), id: \.offset) { _, status in
                        Capsule().fill(color(status)).frame(height: 3)
                    }
                }
            } else {
                TodoProgressBar(progress: TodoProgress(done: summary.done, total: summary.total))
            }
        }
        .accessibilityElement()
        .accessibilityLabel("Progress")
        .accessibilityValue(summary.spoken)
    }

    private func color(_ status: AgentTodo.Status) -> Color {
        switch status {
        case .completed: Theme.success
        case .inProgress: Theme.accent
        case .pending: Theme.textMuted.opacity(0.5)
        }
    }
}

/// A slim bar for how far a list has got: green once it's done.
struct TodoProgressBar: View {
    let progress: TodoProgress

    var body: some View {
        GeometryReader { geometry in
            ZStack(alignment: .leading) {
                Capsule().fill(Theme.cardSelected)
                Capsule()
                    .fill(progress.isComplete ? Theme.success : Theme.accent)
                    .frame(width: max(progress.done > 0 ? 3 : 0, geometry.size.width * progress.fraction))
            }
        }
        .frame(height: 3)
        .accessibilityElement()
        .accessibilityLabel("Progress")
        .accessibilityValue(progress.summary)
    }
}

/// "n done", folding a list's finished items away.
struct TodoDoneDisclosure: View {
    let count: Int
    @Binding var open: Bool

    var body: some View {
        Button {
            MotionPreferences.shared.perform(.sidebar) { open.toggle() }
        } label: {
            HStack(spacing: Theme.Space.xs) {
                OctetIcon("chevron.right", size: 10).rotationEffect(.degrees(open ? 90 : 0))
                Text("\(count) done").font(Theme.Text.caption)
            }
            .foregroundStyle(Theme.textTertiary)
            .padding(.horizontal, Theme.Space.sm)
            .frame(height: 22)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel("\(count) done")
        .accessibilityValue(open ? "Expanded" : "Collapsed")
    }
}

/// A status glyph and its colour, shared by every kind of row.
enum TodoGlyph {
    static func icon(_ status: AgentTodo.Status) -> String {
        switch status {
        case .completed: "tool.todo.done"
        case .inProgress: "tool.todo.active"
        case .pending: "tool.todo.open"
        }
    }

    static func tint(_ status: AgentTodo.Status) -> Color {
        switch status {
        case .completed: Theme.success
        case .inProgress: Theme.accent
        case .pending: Theme.textTertiary
        }
    }

    static func text(_ status: AgentTodo.Status) -> Color {
        switch status {
        case .completed: Theme.textTertiary
        case .inProgress: Theme.textPrimary
        case .pending: Theme.textSecondary
        }
    }

    static func spoken(_ status: AgentTodo.Status) -> String {
        switch status {
        case .completed: "Done"
        case .inProgress: "In progress"
        case .pending: "Not started"
        }
    }
}

/// A section's heading: quiet caps, a heading to VoiceOver.
struct TodoHeading: View {
    let title: String
    var first = true

    var body: some View {
        Text(title.uppercased())
            .font(Theme.headerFont).kerning(0.4)
            .foregroundStyle(Theme.textTertiary)
            .lineLimit(1)
            .padding(.top, first ? 0 : Theme.Space.md)
            .padding(.bottom, Theme.Space.xxs)
            .padding(.horizontal, Theme.Space.sm)
            .accessibilityAddTraits(.isHeader)
    }
}
