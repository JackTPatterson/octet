import AppKit
import SwiftUI

/// One agent's plan: its logo and name, "3 of 5" over a slim bar, the step
/// under way set apart with "now", the steps to come, and the finished ones
/// folded behind "n done". A plan whose turn has finished folds to one
/// line, "done 5/5" or "stopped 3/5", and opens on a click. Read-only: the
/// agent owns it, so a step's menu only copies it or adds it to your list.
struct TodoPlanView: View {
    let section: TodoModel.Section
    let showsTitle: Bool
    @ObservedObject var model: TodoModel
    var focus: FocusState<TodoFocus?>.Binding
    @EnvironmentObject private var window: WindowContext
    @State private var showsDone = false
    @State private var expanded = false
    @State private var hovered = false

    var body: some View {
        let progress = TodoProgress(section.todos)
        let steps = TodoSteps.split(section.todos)
        VStack(alignment: .leading, spacing: Theme.Space.md) {
            header(progress)
            if section.running || expanded {
                TodoProgressBar(progress: progress)
                if !steps.open.isEmpty {
                    VStack(alignment: .leading, spacing: 1) {
                        ForEach(steps.open) { todo in TodoStepRow(todo: todo, section: section, model: model, focus: focus) }
                    }
                }
                if !steps.done.isEmpty, model.filter.showDone {
                    TodoDoneDisclosure(count: steps.done.count, open: $showsDone)
                    if showsDone {
                        VStack(alignment: .leading, spacing: 1) {
                            ForEach(steps.done) { todo in TodoStepRow(todo: todo, section: section, model: model, focus: focus) }
                        }
                    }
                }
            }
        }
    }

    private var name: String {
        if showsTitle || AgentBrand.forAgent(section.agent) == nil { return section.title }
        return AgentBrand.forAgent(section.agent)?.displayName ?? section.title
    }

    private func header(_ progress: TodoProgress) -> some View {
        HStack(spacing: Theme.Space.sm) {
            Button {
                guard !section.running else { return }
                MotionPreferences.shared.perform(.sidebar) { expanded.toggle() }
            } label: {
                HStack(spacing: Theme.Space.sm) {
                    if let brand = AgentBrand.forAgent(section.agent) { AgentLogo(brand: brand, size: 14) }
                    Text(name).font(Theme.Text.bodyMedium).foregroundStyle(Theme.textPrimary).lineLimit(1)
                    if !section.running {
                        Text(progress.isComplete ? "· done \(progress.done)/\(progress.total)" : "· stopped \(progress.done)/\(progress.total)")
                            .font(Theme.Text.caption.monospacedDigit())
                            .foregroundStyle(progress.isComplete ? Theme.success : Theme.warning)
                            .lineLimit(1)
                        OctetIcon("chevron.right", size: 10)
                            .foregroundStyle(Theme.textTertiary)
                            .rotationEffect(.degrees(expanded ? 90 : 0))
                    }
                    Spacer(minLength: Theme.Space.xs)
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .disabled(section.running)
            if hovered || openFocused {
                TodoRowButton(icon: "arrow.up.right", help: section.conversationId != nil ? "Open the conversation" : "Show the pane") {
                    TodoDispatch.open(conversationId: section.conversationId, paneId: section.paneId, tabId: section.tabId, window: window)
                }
            }
            if section.running {
                Text(progress.summary)
                    .font(Theme.Text.caption.monospacedDigit())
                    .foregroundStyle(progress.isComplete ? Theme.success : Theme.textTertiary)
            }
        }
        .onHover { hovered = $0 }
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(name) plan")
        .accessibilityValue(section.running ? progress.summary
                            : "\(progress.isComplete ? "Done" : "Stopped"), \(progress.done) of \(progress.total)")
        .accessibilityAddTraits(.isHeader)
        .accessibilityAction(named: section.conversationId != nil ? "Open the conversation" : "Show the pane") {
            TodoDispatch.open(conversationId: section.conversationId, paneId: section.paneId, tabId: section.tabId, window: window)
        }
    }

    private var openFocused: Bool {
        if case .step(let id, _) = focus.wrappedValue { return id == section.id }
        return false
    }
}

/// A step of an agent's plan.
private struct TodoStepRow: View {
    let todo: AgentTodo
    let section: TodoModel.Section
    @ObservedObject var model: TodoModel
    var focus: FocusState<TodoFocus?>.Binding
    @State private var hovered = false

    private var focusId: TodoFocus { .step(section.id, todo.id) }

    var body: some View {
        let active = todo.status == .inProgress
        let focused = focus.wrappedValue == focusId
        HStack(alignment: .firstTextBaseline, spacing: Theme.Space.md) {
            OctetIcon(TodoGlyph.icon(todo.status), size: 13)
                .foregroundStyle(TodoGlyph.tint(todo.status))
                .alignmentGuide(.firstTextBaseline) { $0[VerticalAlignment.center] + 4 }
            VStack(alignment: .leading, spacing: Theme.Space.xxs) {
                Text(todo.shownText)
                    .font(active ? Theme.Text.bodyMedium : Theme.Text.body)
                    .foregroundStyle(TodoGlyph.text(todo.status))
                    .strikethrough(todo.status == .completed, color: Theme.textTertiary)
                    .fixedSize(horizontal: false, vertical: true)
                if hovered || active || focused, let detail = todo.detail, !detail.isEmpty {
                    Text(detail)
                        .font(Theme.Text.caption)
                        .foregroundStyle(Theme.textTertiary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            Spacer(minLength: 0)
            if active, section.running {
                Text("now").font(Theme.Text.micro).foregroundStyle(Theme.textTertiary)
            }
        }
        .padding(.horizontal, Theme.Space.sm)
        .padding(.vertical, active ? Theme.Space.sm : Theme.Space.xs)
        .background(RoundedRectangle(cornerRadius: Theme.Radius.lg)
            .fill(active ? Theme.accent.opacity(0.1) : hovered || focused ? Theme.hover : Color.clear))
        .overlay(RoundedRectangle(cornerRadius: Theme.Radius.lg).strokeBorder(Theme.accent, lineWidth: focused ? 1 : 0))
        .contentShape(Rectangle())
        .focusable()
        .focused(focus, equals: focusId)
        .focusEffectDisabled()
        .onHover { hovered = $0 }
        .modifier(OptionalHelp(text: todo.detail))
        .contextMenu {
            Button("Add to My Todos") { model.add(todo.text, to: .mine) }
            Button("Copy") { copy() }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(todo.shownText)
        .accessibilityValue(TodoGlyph.spoken(todo.status))
        .accessibilityAction(named: "Add to my todos") { model.add(todo.text, to: .mine) }
        .accessibilityAction(named: "Copy") { copy() }
    }

    private func copy() {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(todo.text, forType: .string)
    }
}

/// A plan an agent proposed and is waiting on, in plan mode: its title and
/// first lines, and what to do with it, the same Implement the composer's
/// banner offers, or kept as todos in the project's list.
struct ProposedPlanCard: View {
    let proposed: TodoModel.ProposedPlan
    @ObservedObject var model: TodoModel
    @State private var expanded = false

    var body: some View {
        let lines = proposed.plan.markdown.components(separatedBy: .newlines)
        VStack(alignment: .leading, spacing: Theme.Space.sm) {
            HStack(spacing: Theme.Space.sm) {
                Text("Plan")
                    .font(Theme.Text.captionMedium)
                    .foregroundStyle(Theme.info)
                    .padding(.horizontal, Theme.Space.xs)
                    .padding(.vertical, Theme.Space.xxs)
                    .background(RoundedRectangle(cornerRadius: Theme.Radius.xs).fill(Theme.info.opacity(0.14)))
                if let brand = AgentBrand.forAgent(proposed.agent) { AgentLogo(brand: brand, size: 12) }
                Text(proposed.plan.title ?? "Proposed plan")
                    .font(Theme.Text.bodyMedium).foregroundStyle(Theme.textPrimary).lineLimit(1)
                Spacer(minLength: Theme.Space.xs)
                Menu { menuItems } label: {
                    OctetIcon("ellipsis", size: 12).foregroundStyle(Theme.textSecondary).frame(width: 18, height: 18)
                }
                .menuStyle(.borderlessButton)
                .menuIndicator(.hidden)
                .fixedSize()
                .help("More")
                .accessibilityLabel("Plan actions")
            }
            Text((expanded ? lines : Array(lines.prefix(6))).joined(separator: "\n"))
                .font(Theme.Text.caption)
                .foregroundStyle(Theme.textSecondary)
                .fixedSize(horizontal: false, vertical: true)
                .textSelection(.enabled)
            HStack(spacing: Theme.Space.sm) {
                if lines.count > 6 {
                    OctetButton(title: expanded ? "Collapse" : "Expand plan", kind: .ghost, compact: true) {
                        MotionPreferences.shared.perform(.sidebar) { expanded.toggle() }
                    }
                }
                Spacer()
                OctetButton(title: "Implement", kind: .primary, compact: true) { implement() }
            }
        }
        .padding(Theme.Space.lg)
        .background(RoundedRectangle(cornerRadius: Theme.Radius.card).fill(Theme.card))
        .contextMenu { menuItems }
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Proposed plan: \(proposed.plan.title ?? "")")
    }

    @ViewBuilder
    private var menuItems: some View {
        Button("Implement") { implement() }
        Button("Copy") {
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(proposed.plan.markdown, forType: .string)
        }
        Button("Save to \(ProjectTodos.fileNames[0]) as a Checklist") { model.saveToProject(proposed.plan) }
            .disabled(model.projectRoot == nil)
    }

    /// Out of plan mode, asking before edits, and the plan sent to carry
    /// out, as the composer's banner does.
    private func implement() {
        guard let session = AgentCenter.shared.sessions.first(where: { $0.id == proposed.sessionId }) else { return }
        switch session.engine {
        case .claude: session.permissionMode = .default
        case .opencode: session.agentName = nil
        default: break
        }
        session.send(ComposerPlanFollowUp.implementationPrompt(proposed.plan))
        model.refresh()
    }
}

/// What the workspace is tied to: the checkout's issue, with its status and
/// any checkboxes in its description, and the waits set from here.
struct TodoLinkedSection: View {
    @ObservedObject var model: TodoModel
    @EnvironmentObject private var window: WindowContext

    var body: some View {
        VStack(alignment: .leading, spacing: Theme.Space.sm) {
            HStack(spacing: Theme.Space.sm) {
                OctetIcon("link", size: 14).foregroundStyle(Theme.textTertiary)
                Text("Linked").font(Theme.Text.bodyMedium).foregroundStyle(Theme.textPrimary)
                Spacer()
            }
            .accessibilityAddTraits(.isHeader)
            if let issue = model.issue { issueRow(issue) }
            if !model.waits.isEmpty {
                VStack(alignment: .leading, spacing: 1) {
                    TodoHeading(title: "Waits", first: model.issue == nil)
                    ForEach(model.waits) { wait in waitRow(wait) }
                }
            }
        }
    }

    private func issueRow(_ issue: TodoModel.LinkedIssue) -> some View {
        VStack(alignment: .leading, spacing: Theme.Space.xs) {
            HStack(alignment: .firstTextBaseline, spacing: Theme.Space.md) {
                TodoChip(tint: Theme.textSecondary) { Text(issue.link.key).monospaced() }
                Text(issue.link.title)
                    .font(Theme.Text.body).foregroundStyle(Theme.textPrimary)
                    .lineLimit(2).fixedSize(horizontal: false, vertical: true)
                Spacer(minLength: 0)
                if let status = issue.status {
                    Text(status).font(Theme.Text.micro).foregroundStyle(issue.closed ? Theme.success : Theme.textTertiary)
                }
                Menu { issueMenu(issue) } label: {
                    OctetIcon("ellipsis", size: 12).foregroundStyle(Theme.textSecondary).frame(width: 18, height: 18)
                }
                .menuStyle(.borderlessButton)
                .menuIndicator(.hidden)
                .fixedSize()
                .accessibilityLabel("Issue actions")
            }
            .padding(.horizontal, Theme.Space.sm)
            .contextMenu { issueMenu(issue) }
            .accessibilityElement(children: .combine)
            .accessibilityValue(issue.status ?? "")
            ForEach(issue.steps) { step in
                HStack(alignment: .firstTextBaseline, spacing: Theme.Space.md) {
                    OctetIcon(TodoGlyph.icon(step.status), size: 13).foregroundStyle(TodoGlyph.tint(step.status))
                    Text(step.text).font(Theme.Text.body).foregroundStyle(TodoGlyph.text(step.status))
                        .strikethrough(step.status == .completed, color: Theme.textTertiary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                .padding(.horizontal, Theme.Space.sm)
                .accessibilityElement(children: .ignore)
                .accessibilityLabel(step.text)
                .accessibilityValue(TodoGlyph.spoken(step.status))
            }
        }
    }

    @ViewBuilder
    private func issueMenu(_ issue: TodoModel.LinkedIssue) -> some View {
        if let url = issue.link.url { Button("Open \(issue.link.key)") { NSWorkspace.shared.open(url) } }
        Menu("Start a Conversation") {
            ForEach(TodoDispatch.engines, id: \.self) { engine in
                Button(engine.displayName) { startConversation(engine, issue: issue) }
            }
        }
        Button("Copy Prompt") {
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(Self.prompt(issue), forType: .string)
        }
    }

    /// Orca's read-the-ticket opener, with the issue named.
    static func prompt(_ issue: TodoModel.LinkedIssue) -> String {
        "Read the linked issue for this worktree, \(issue.link.key): \(issue.link.title)"
            + (issue.link.url.map { " (\($0.absoluteString))" } ?? "")
            + ", then summarize the goal and acceptance criteria before you start."
    }

    private func startConversation(_ engine: AgentSession.Engine, issue: TodoModel.LinkedIssue) {
        guard let workspaceId = window.focusedWorkspace?.workspaceId else { return }
        let cwd = window.store.snapshot.directory(ofWorkspace: workspaceId) ?? model.projectRoot ?? NSHomeDirectory()
        AgentCenter.shared.newConversation(workspaceId: workspaceId, cwd: cwd, engine: engine).send(Self.prompt(issue))
    }

    private func waitRow(_ wait: Wait) -> some View {
        Button { WaitCenter.shared.checkNow(wait.id) } label: {
            HStack(alignment: .firstTextBaseline, spacing: Theme.Space.md) {
                OctetIcon("hourglass", size: 13).foregroundStyle(tint(wait))
                Text(wait.title).font(Theme.Text.body).foregroundStyle(Theme.textSecondary).lineLimit(2)
                Spacer(minLength: 0)
                Text(TodoWaitLabel.short(wait)).font(Theme.Text.micro).foregroundStyle(tint(wait))
            }
            .padding(.horizontal, Theme.Space.sm)
            .padding(.vertical, Theme.Space.xs)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help("\(wait.condition.description). Click to check now.")
        .accessibilityLabel(wait.title)
        .accessibilityValue(wait.condition.description)
        .accessibilityHint("Checks it now")
    }

    private func tint(_ wait: Wait) -> Color {
        if wait.state == .ready { return Theme.warning }
        if case .date = wait.condition { return Theme.info }
        return Theme.textTertiary
    }
}
