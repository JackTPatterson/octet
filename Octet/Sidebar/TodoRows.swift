import AppKit
import SwiftUI
import UniformTypeIdentifiers

/// Your todos or the project's: the open items under their headings, the
/// finished ones folded behind "n done", and (for yours) the field to add
/// one. The project's list, when there's no `TODO.md`, is only a button to
/// start one, so nothing lands in the repository by accident.
struct TodoListSection: View {
    let kind: TodoModel.ListKind
    @ObservedObject var model: TodoModel
    var focus: FocusState<TodoFocus?>.Binding
    @State private var showsDone = false

    var body: some View {
        let list = model.list(kind)
        VStack(alignment: .leading, spacing: Theme.Space.sm) {
            header(list)
            if kind == .mine { TodoAddField(model: model, focus: focus) }
            if kind == .project, list == nil {
                OctetButton(title: "Start \(ProjectTodos.fileNames[0])", icon: "plus", kind: .ghost, compact: true) {
                    model.startProjectList()
                }
                .help("Makes \(ProjectTodos.fileNames[0]) at the project root: a list agents and teammates can read and tick")
            } else if let list, !list.items.isEmpty {
                let open = list.items.filter { $0.status != .completed || model.lingering.contains($0.id) }
                let done = list.items.filter { $0.status == .completed && !model.lingering.contains($0.id) }
                rows(open)
                if !done.isEmpty, model.filter.showDone {
                    TodoDoneDisclosure(count: done.count, open: $showsDone)
                    if showsDone { rows(done) }
                }
            } else if kind == .project {
                Text("\((list?.path as NSString?)?.lastPathComponent ?? "TODO.md") has no checkbox items yet (- [ ] like this).")
                    .font(Theme.Text.caption)
                    .foregroundStyle(Theme.textTertiary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    private func header(_ list: ProjectTodoList?) -> some View {
        HStack(spacing: Theme.Space.sm) {
            OctetIcon(kind == .mine ? "person.crop.circle" : "folder", size: 14).foregroundStyle(Theme.textTertiary)
            Text(kind == .mine ? "Mine" : ((model.projectRoot ?? "") as NSString).lastPathComponent)
                .font(Theme.Text.bodyMedium).foregroundStyle(Theme.textPrimary).lineLimit(1)
            Text(kind == .mine ? "only in this checkout" : (model.path(of: .project) as NSString?)?.lastPathComponent ?? "")
                .font(Theme.Text.caption).foregroundStyle(Theme.textTertiary).lineLimit(1)
            Spacer(minLength: Theme.Space.xs)
            if let list, !list.items.isEmpty {
                let progress = TodoProgress(done: list.done.count, total: list.items.count)
                Text(progress.summary)
                    .font(Theme.Text.caption.monospacedDigit())
                    .foregroundStyle(progress.isComplete ? Theme.success : Theme.textTertiary)
            }
        }
        .help(kind == .mine
              ? "Kept in this checkout's git folder, never committed: \(abbreviateHome(model.minePath ?? ""))"
              : (model.path(of: .project).map(abbreviateHome) ?? ""))
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(.isHeader)
    }

    /// Rows under their headings.
    private func rows(_ items: [ProjectTodoList.Item]) -> some View {
        let groups = ProjectTodoGrouping.groups(items)
        return VStack(alignment: .leading, spacing: 1) {
            ForEach(Array(groups.enumerated()), id: \.element.id) { index, group in
                if let title = group.title { TodoHeading(title: title, first: index == 0) }
                ForEach(group.items) { item in
                    TodoListRow(item: item, kind: kind, model: model, focus: focus)
                        .transition(MotionPreferences.shared.animates(.sidebar) ? .opacity.combined(with: .move(edge: .top)) : .identity)
                }
            }
        }
        .animation(MotionPreferences.shared.animation(.sidebar, .smooth(duration: 0.2)), value: items.map(\.id))
    }
}

/// The field at the top of your list. Return adds and stays for the next
/// one; Shift-Return adds and sends it to the agent in front; Escape
/// clears, then leaves. Several lines pasted make several items.
struct TodoAddField: View {
    @ObservedObject var model: TodoModel
    var focus: FocusState<TodoFocus?>.Binding
    @EnvironmentObject private var window: WindowContext
    @State private var draft = ""

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: Theme.Space.md) {
                OctetIcon("plus", size: 13).foregroundStyle(Theme.textTertiary)
                TextField("Add a todo", text: $draft)
                    .textFieldStyle(.plain)
                    .font(Theme.Text.body)
                    .focused(focus, equals: .add)
                    .onSubmit { add(send: false) }
                    .onKeyPress(.return, phases: .down) { press in
                        guard press.modifiers.contains(.shift) else { return .ignored }
                        add(send: true)
                        return .handled
                    }
                    .onExitCommand {
                        if draft.isEmpty { focus.wrappedValue = nil } else { draft = "" }
                    }
                    .accessibilityLabel("Add a todo")
                    .accessibilityHint("Return adds it. Shift-Return adds it and sends it to the agent in front.")
            }
            .padding(.horizontal, Theme.Space.sm)
            .frame(height: 28)
            Rectangle().fill(Theme.divider).frame(height: 1)
        }
    }

    private func add(send: Bool) {
        let text = draft.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return }
        draft = ""
        model.add(text, to: .mine)
        focus.wrappedValue = .add
        guard send else { return }
        guard let target = TodoDispatch.inFront(window) else {
            ToastCenter.shared.info("No agent here to send it to", detail: "Added to your todos. Start an agent, then send it from the row.")
            return
        }
        // Sent once it's in the file and read back, so its line is known.
        let firstLine = text.components(separatedBy: .newlines).first ?? text
        sendWhenListed(firstLine, to: target, tries: 8)
    }

    private func sendWhenListed(_ text: String, to target: TodoDispatch.Target, tries: Int) {
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.25) {
            if let item = model.mine?.items.last(where: { $0.text == text && $0.status == .pending }) {
                TodoDispatch.send(item, in: .mine, to: target, model: model, window: window)
            } else if tries > 0 {
                sendWhenListed(text, to: target, tries: tries - 1)
            }
        }
    }
}

/// One of your todos or the project's. Its glyph ticks it (⌥-click marks
/// it under way); its text rewords it on a double-click; Send and More show
/// on hover or keyboard focus, and every action is in its context menu and
/// in VoiceOver's actions too.
struct TodoListRow: View {
    let item: ProjectTodoList.Item
    let kind: TodoModel.ListKind
    @ObservedObject var model: TodoModel
    var focus: FocusState<TodoFocus?>.Binding
    @EnvironmentObject private var window: WindowContext
    @ObservedObject private var editing = TodoRowEditing.shared
    @ObservedObject private var motion = MotionPreferences.shared
    @State private var hovered = false
    @State private var draft = ""
    @State private var linking = false
    @State private var issueKey = ""
    @State private var dropTargeted = false
    @State private var truncated = false
    @FocusState private var editorFocused: Bool

    private var focusId: TodoFocus { .item(kind, item.id) }
    private var isEditing: Bool { editing.editing == focusId }
    private var focused: Bool { focus.wrappedValue == focusId }

    var body: some View {
        let active = item.status == .inProgress
        let link = model.link(for: item)
        HStack(alignment: .firstTextBaseline, spacing: Theme.Space.md) {
            glyph
            if isEditing { editor } else { text(active: active) }
            Spacer(minLength: 0)
            meta(link)
            if (hovered || focused) && !isEditing { actions }
        }
        .padding(.horizontal, Theme.Space.sm)
        .padding(.vertical, active ? Theme.Space.sm : Theme.Space.xs)
        .frame(minHeight: 24)
        .background(RoundedRectangle(cornerRadius: Theme.Radius.lg)
            .fill(active ? Theme.accent.opacity(0.1) : hovered || focused ? Theme.hover : Color.clear))
        .overlay(RoundedRectangle(cornerRadius: Theme.Radius.lg).strokeBorder(Theme.accent, lineWidth: focused ? 1 : 0))
        .overlay(alignment: .top) {
            if dropTargeted { Rectangle().fill(Theme.accent).frame(height: 2).offset(y: -1) }
        }
        .contentShape(Rectangle())
        .focusable(!isEditing)
        .focused(focus, equals: focusId)
        .focusEffectDisabled()
        .onHover { hovered = $0 }
        .onTapGesture { focus.wrappedValue = focusId }
        .contextMenu { menuItems }
        .draggable(item.id) { Text(item.text).font(Theme.Text.body).padding(Theme.Space.sm) }
        .dropDestination(for: String.self) { ids, _ in
            guard let id = ids.first, let moving = model.list(kind)?.items.first(where: { $0.id == id }) else { return false }
            model.move(moving, before: item, in: kind)
            return true
        } isTargeted: { dropTargeted = $0 && item.status != .completed }
        .popover(isPresented: $linking, arrowEdge: .leading) { linkPopover }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(item.text)
        .accessibilityValue(spokenValue(link))
        .accessibilityActions { accessibilityActions }
    }

    // MARK: - Parts

    private var glyph: some View {
        Button {
            let option = NSEvent.modifierFlags.contains(.option)
            MotionPreferences.shared.perform(.sidebar) {
                model.set(item, in: kind, to: option ? .inProgress : item.status == .completed ? .pending : .completed)
            }
        } label: {
            OctetIcon(TodoGlyph.icon(item.status), size: 13)
                .foregroundStyle(TodoGlyph.tint(item.status))
                .contentShape(Rectangle())
                .id(item.status)
                .transition(motion.animates(.sidebar) ? .scale(scale: 0.85).combined(with: .opacity) : .identity)
        }
        .buttonStyle(.plain)
        .alignmentGuide(.firstTextBaseline) { $0[VerticalAlignment.center] + 4 }
        .help(item.status == .completed ? "Mark as not done (⌥-click: in progress)" : "Mark as done (⌥-click: in progress)")
        .accessibilityLabel(item.status == .completed ? "Mark as not done" : "Mark as done")
    }

    private func text(active: Bool) -> some View {
        Text(item.text)
            .font(active ? Theme.Text.bodyMedium : Theme.Text.body)
            .foregroundStyle(TodoGlyph.text(item.status))
            .strikethrough(item.status == .completed, color: Theme.textTertiary)
            .lineLimit(3)
            .fixedSize(horizontal: false, vertical: true)
            .background(TruncationReader(text: item.text, lines: 3) { truncated = $0 })
            .modifier(OptionalHelp(text: truncated ? item.text : nil))
            .onTapGesture(count: 2) { beginEditing() }
    }

    private var editor: some View {
        TextField("Todo", text: $draft)
            .textFieldStyle(.plain)
            .font(Theme.Text.body)
            .foregroundStyle(Theme.textPrimary)
            .focused($editorFocused)
            .onSubmit { finishEditing(save: true) }
            .onExitCommand { finishEditing(save: false) }
            .onAppear {
                draft = item.text
                editorFocused = true
            }
    }

    @ViewBuilder
    private func meta(_ link: TodoLink?) -> some View {
        HStack(spacing: Theme.Space.xs) {
            if let link, let agentName = link.agentName, item.status != .completed {
                TodoChip {
                    if let brand = AgentBrand.forAgent(link.agent) { AgentLogo(brand: brand, size: 12) }
                    Text("with \(agentName)")
                }
                .help(link.conversationId != nil ? "Sent to \(agentName); click to open the conversation" : "Sent to \(agentName)")
                .onTapGesture {
                    TodoDispatch.open(conversationId: link.conversationId, paneId: nil, tabId: nil, window: window)
                }
            }
            if let key = link?.issueKey {
                TodoChip { Text(key).monospaced() }
                    .help("Linked to \(key)")
                    .onTapGesture { openIssue(link) }
            }
            if let wait = model.wait(for: item) {
                TodoChip(tint: Theme.info) { Text(TodoWaitLabel.short(wait)) }
                    .help(wait.condition.description)
            }
        }
    }

    private var actions: some View {
        HStack(spacing: Theme.Space.xxs) {
            if item.status != .completed, let target = TodoDispatch.inFront(window) {
                TodoRowButton(icon: "arrow.right", help: "Send to \(target.name): it works on this and ticks it off") {
                    TodoDispatch.send(item, in: kind, to: target, model: model, window: window)
                }
            }
            OctetMenuButton({ menuList }) {
                OctetIcon("ellipsis", size: 12)
                    .foregroundStyle(Theme.textSecondary)
                    .frame(width: 18, height: 18)
                    .contentShape(Rectangle())
            }
            .fixedSize()
            .help("More")
            .accessibilityLabel("More actions")
        }
    }

    @ViewBuilder
    private var menuItems: some View {
        let targets = TodoDispatch.targets(in: window)
        Button("Edit") { beginEditing() }
        if item.status != .inProgress {
            Button("Mark In Progress") { model.set(item, in: kind, to: .inProgress) }
        }
        Divider()
        if !targets.isEmpty {
            Menu("Send To") {
                ForEach(targets) { target in
                    Button(target.name) { TodoDispatch.send(item, in: kind, to: target, model: model, window: window) }
                }
            }
        }
        Menu("Start a Conversation") {
            ForEach(TodoDispatch.engines, id: \.self) { engine in
                Button(engine.displayName) { TodoDispatch.start(item, in: kind, engine: engine, model: model, window: window) }
            }
        }
        Button("Wait on This…") { waitOn() }
        Button(model.link(for: item)?.issueKey == nil ? "Link to Issue…" : "Change Linked Issue…") {
            issueKey = model.link(for: item)?.issueKey ?? ""
            linking = true
        }
        if model.link(for: item)?.issueKey != nil {
            Button("Unlink Issue") { model.updateLink(item) { $0.issueKey = nil; $0.issueURL = nil } }
        }
        Divider()
        Button(kind == .mine ? "Move to \(ProjectTodos.fileNames[0])" : "Move to My Todos") { model.transfer(item, from: kind) }
            .disabled(kind == .mine && model.projectRoot == nil)
        Button("Copy") {
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(item.text, forType: .string)
        }
        Divider()
        Button("Delete", role: .destructive) { model.delete(item, in: kind) }
    }

    /// `menuItems` as an Octet menu, for the "More" button.
    private var menuList: [OctetMenuItem] {
        let targets = TodoDispatch.targets(in: window)
        var items: [OctetMenuItem] = [.action("Edit") { beginEditing() }]
        if item.status != .inProgress {
            items.append(.action("Mark In Progress") { model.set(item, in: kind, to: .inProgress) })
        }
        items.append(.divider)
        if !targets.isEmpty {
            items.append(.submenu("Send To", targets.map { target in
                OctetMenuItem.action(target.name) { TodoDispatch.send(item, in: kind, to: target, model: model, window: window) }
            }))
        }
        items.append(.submenu("Start a Conversation", TodoDispatch.engines.map { engine in
            OctetMenuItem.action(engine.displayName) { TodoDispatch.start(item, in: kind, engine: engine, model: model, window: window) }
        }))
        items.append(.action("Wait on This…") { waitOn() })
        items.append(.action(model.link(for: item)?.issueKey == nil ? "Link to Issue…" : "Change Linked Issue…") {
            issueKey = model.link(for: item)?.issueKey ?? ""
            linking = true
        })
        if model.link(for: item)?.issueKey != nil {
            items.append(.action("Unlink Issue") { model.updateLink(item) { $0.issueKey = nil; $0.issueURL = nil } })
        }
        items.append(.divider)
        items.append(.action(kind == .mine ? "Move to \(ProjectTodos.fileNames[0])" : "Move to My Todos",
                             enabled: !(kind == .mine && model.projectRoot == nil)) { model.transfer(item, from: kind) })
        items.append(.action("Copy") {
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(item.text, forType: .string)
        })
        items.append(.divider)
        items.append(.action("Delete", destructive: true) { model.delete(item, in: kind) })
        return items
    }

    @ViewBuilder
    private var accessibilityActions: some View {
        Button(item.status == .completed ? "Mark not done" : "Mark done") {
            model.set(item, in: kind, to: item.status == .completed ? .pending : .completed)
        }
        if item.status != .inProgress { Button("Mark in progress") { model.set(item, in: kind, to: .inProgress) } }
        Button("Edit") { beginEditing() }
        ForEach(TodoDispatch.targets(in: window)) { target in
            Button("Send to \(target.name)") { TodoDispatch.send(item, in: kind, to: target, model: model, window: window) }
        }
        ForEach(TodoDispatch.engines, id: \.self) { engine in
            Button("Start a \(engine.displayName) conversation") {
                TodoDispatch.start(item, in: kind, engine: engine, model: model, window: window)
            }
        }
        Button("Wait on this") { waitOn() }
        Button("Link to issue") { linking = true }
        Button("Move up") { model.move(item, in: kind, by: -1) }
        Button("Move down") { model.move(item, in: kind, by: 1) }
        Button(kind == .mine ? "Move to the project's list" : "Move to my todos") { model.transfer(item, from: kind) }
        Button("Delete") { model.delete(item, in: kind) }
    }

    private var linkPopover: some View {
        VStack(alignment: .leading, spacing: Theme.Space.sm) {
            Text("Link to an issue").font(Theme.Text.bodyMedium).foregroundStyle(Theme.textPrimary)
            OctetTextField(placeholder: model.issue?.link.key ?? "CLX-12 or #142", text: $issueKey, label: "Issue key",
                           onSubmit: saveLink, focusRequest: 1)
                .frame(width: 200)
            HStack {
                if let linked = model.issue?.link, issueKey.isEmpty {
                    OctetButton(title: "Use \(linked.key)", kind: .ghost, compact: true) {
                        issueKey = linked.key
                        saveLink()
                    }
                }
                Spacer()
                OctetButton(title: "Link", kind: .primary, compact: true, action: saveLink)
                    .disabled(issueKey.trimmingCharacters(in: .whitespaces).isEmpty)
            }
        }
        .padding(Theme.Space.lg)
    }

    // MARK: - Actions

    private func beginEditing() {
        editing.editing = focusId
    }

    private func finishEditing(save: Bool) {
        if save { model.rename(item, in: kind, to: draft) }
        editing.editing = nil
        focus.wrappedValue = focusId
    }

    private func saveLink() {
        let key = issueKey.trimmingCharacters(in: .whitespaces)
        guard !key.isEmpty else { return }
        linking = false
        // The checkout's own issue opens where it lives; any other is looked
        // up in the same tracker when it's opened.
        let url = model.issue?.link.key == key ? model.issue?.link.url : nil
        model.updateLink(item) {
            $0.issueKey = key
            $0.issueURL = url
        }
    }

    private func openIssue(_ link: TodoLink?) {
        guard let key = link?.issueKey else { return }
        if let url = link?.issueURL ?? (model.issue?.link.key == key ? model.issue?.link.url : nil) {
            NSWorkspace.shared.open(url)
            return
        }
        guard let tracker = model.issue.flatMap({ IssueTracker(rawValue: $0.link.tracker) }) ?? (key.hasPrefix("#") ? .github : nil) else {
            ToastCenter.shared.info("Couldn't tell which tracker \(key) is in", detail: "Link this checkout to an issue in the Tickets pane first.")
            return
        }
        let directory = model.projectRoot
        Task {
            do {
                let found = try await IssueService.issue(tracker: tracker, key: key, connectionId: model.issue?.link.connectionId,
                                                         directory: directory)
                if let url = found.url {
                    model.updateLink(item) { $0.issueURL = url }
                    NSWorkspace.shared.open(url)
                }
            } catch {
                ToastCenter.shared.fail(nil, "Couldn't open \(key)", detail: error.localizedDescription)
            }
        }
    }

    /// A wait for tomorrow morning with this item as the next step; when it
    /// comes round, the waits start a conversation with it.
    private func waitOn() {
        WaitCenter.shared.compose(workspaceId: window.focusedWorkspace?.workspaceId)
        guard var draft = WaitCenter.shared.draft else { return }
        draft.kind = .date
        draft.title = item.text
        draft.next = TodoDispatch.prompt(for: item, in: kind, model: model)
        WaitCenter.shared.draft = draft
    }

    private func spokenValue(_ link: TodoLink?) -> String {
        var parts = [TodoGlyph.spoken(item.status)]
        if let name = link?.agentName, item.status != .completed { parts.append("with \(name)") }
        if let key = link?.issueKey { parts.append("linked \(key)") }
        if let wait = model.wait(for: item) { parts.append(TodoWaitLabel.short(wait)) }
        return parts.joined(separator: ", ")
    }
}

/// "Waiting · Thu" for a wait on a date, else just "Waiting".
enum TodoWaitLabel {
    static func short(_ wait: Wait) -> String {
        guard case .date(let date) = wait.condition else { return "Waiting" }
        let calendar = Calendar.current
        if calendar.isDateInTomorrow(date) { return "Waiting · Tomorrow" }
        if calendar.isDateInToday(date) { return "Waiting · Today" }
        return "Waiting · " + date.formatted(.dateTime.weekday(.abbreviated))
    }
}

/// A small chip on a row's right: who has it, what it's linked to.
struct TodoChip<Content: View>: View {
    var tint: Color = Theme.textTertiary
    @ViewBuilder let content: Content

    var body: some View {
        HStack(spacing: Theme.Space.xxs) { content }
            .font(Theme.Text.micro)
            .foregroundStyle(tint)
            .lineLimit(1)
            .padding(.horizontal, Theme.Space.xs)
            .padding(.vertical, Theme.Space.xxs)
            .background(RoundedRectangle(cornerRadius: Theme.Radius.xs).fill(Theme.hover))
            .fixedSize()
    }
}

/// An 18pt row action, labelled for VoiceOver from its help.
struct TodoRowButton: View {
    let icon: String
    let help: String
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            OctetIcon(icon, size: 12)
                .foregroundStyle(Theme.textSecondary)
                .frame(width: 18, height: 18)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help(help)
        .accessibilityLabel(help)
    }
}

/// Whether a text at the width it's given would run past `lines` lines,
/// for a tooltip only when some of it is hidden.
struct TruncationReader: View {
    let text: String
    let lines: Int
    let changed: (Bool) -> Void

    var body: some View {
        GeometryReader { proxy in
            Color.clear
                .onAppear { measure(proxy.size.width) }
                .onChange(of: proxy.size.width) { _, width in measure(width) }
                .onChange(of: text) { _, _ in measure(proxy.size.width) }
        }
    }

    private func measure(_ width: CGFloat) {
        guard width > 0 else { return }
        let font = NSFont.systemFont(ofSize: 12)
        let height = (text as NSString).boundingRect(with: NSSize(width: width, height: .greatestFiniteMagnitude),
                                                     options: [.usesLineFragmentOrigin], attributes: [.font: font]).height
        changed(height > font.boundingRectForFont.height * CGFloat(lines) + 1)
    }
}
