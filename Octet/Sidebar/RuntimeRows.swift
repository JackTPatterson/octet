import AppKit
import SwiftUI

extension AgentState {
    /// A runtime row's state mark beside its text, so colour never carries
    /// it alone; working has none (the glyph's spinner says it).
    var runtimeIcon: String? {
        switch self {
        case .working: nil
        case .waiting: "pause.circle"
        case .done: "checkmark.circle"
        case .idle, .unknown: nil
        default: icon
        }
    }
}

/// One clock for every live time in the panel: a row's elapsed time reads
/// it instead of running a timeline of its own. It ticks only while some
/// label is on screen.
@MainActor
final class RuntimeClock: ObservableObject {
    static let shared = RuntimeClock()
    @Published private(set) var now = Date()
    private var timer: Timer?
    private var watchers = 0

    func watch() {
        watchers += 1
        guard timer == nil else { return }
        now = Date()
        let timer = Timer(timeInterval: 1, repeats: true) { _ in
            MainActor.assumeIsolated { RuntimeClock.shared.now = Date() }
        }
        RunLoop.main.add(timer, forMode: .common)
        self.timer = timer
    }

    func unwatch() {
        watchers = max(0, watchers - 1)
        guard watchers == 0 else { return }
        timer?.invalidate()
        timer = nil
    }
}

/// A time that ticks from the shared clock: elapsed while working, how long
/// ago once finished. Drawn apart from the activity text, so a tick never
/// restarts that line's transition.
struct RuntimeTimeLabel: View {
    enum Mode { case elapsed, ago }
    let date: Date
    let mode: Mode
    @ObservedObject private var clock = RuntimeClock.shared

    var body: some View {
        Text(mode == .elapsed ? CompactFormat.elapsed(clock.now.timeIntervalSince(date))
                              : RuntimeText.ago(clock.now.timeIntervalSince(date)))
            .monospacedDigit()
            .onAppear { clock.watch() }
            .onDisappear { clock.unwatch() }
    }
}

/// A plan's steps as a thin strip and "3/7": done in success, the step under
/// way in the accent, the rest faint.
struct RuntimeTodoMeter: View {
    let meter: TodoMeter

    var body: some View {
        HStack(spacing: Theme.Space.xs) {
            HStack(spacing: 1) {
                ForEach(Array(meter.segments.enumerated()), id: \.offset) { _, status in
                    Capsule().fill(color(status)).frame(height: 3)
                }
            }
            .frame(width: 40)
            Text(meter.label).monospacedDigit()
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(meter.spoken)
    }

    private func color(_ status: AgentTodo.Status) -> Color {
        switch status {
        case .completed: Theme.success
        case .inProgress: Theme.accent
        case .pending: Theme.textTertiary.opacity(0.25)
        }
    }
}

/// One runtime, as a flat row of two lines: its mark with its state on the
/// corner, its title and a time (or its state, when that needs you), then
/// what it's doing or what it came to. A click opens its details beneath
/// it; the pointer (or a menu) brings its actions.
struct RuntimeRow: View {
    let entry: RuntimeEntry
    let flashes: Bool
    let expanded: Bool
    let toggle: () -> Void
    let focus: (() -> Void)?
    let stop: (() -> Void)?
    let menu: () -> [OctetMenuItem]
    var childCount: Int = 0
    /// Compact rows: the title line only.
    var compactRows = false
    /// Finished or failed since you last looked: a dot in the gutter.
    var unread = false
    /// The keyboard's row, ringed.
    var selected = false
    /// The pointer moved onto it: it becomes the keyboard's row too.
    var select: (() -> Void)? = nil
    var markRead: (() -> Void)? = nil
    var copyOutput: (() -> Void)? = nil
    var openOutput: (() -> Void)? = nil
    var branchCollapsed = false
    var toggleBranch: (() -> Void)? = nil
    /// The mark its tree edge comes from (a row's id, or its group's), and
    /// its place in the drawing order.
    var treeParent: String? = nil
    var treeOrder = 0
    @ObservedObject private var motion = MotionPreferences.shared
    @State private var hovered = false

    private var isShell: Bool { entry.kind == .shell }

    var body: some View {
        HStack(alignment: .top, spacing: 0) {
            if entry.depth > 0 {
                TreeConnector(depth: entry.depth)
            }
            VStack(alignment: .leading, spacing: 0) {
                summary
                if expanded {
                    RuntimeDetails(entry: entry, focus: focus, openOutput: openOutput)
                        .transition(motion.animates(.sidebar)
                            ? .asymmetric(insertion: .opacity.combined(with: .offset(y: -4)), removal: .opacity)
                            : .identity)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(RoundedRectangle(cornerRadius: Theme.Radius.sm)
                .fill(flashes ? entry.tint.opacity(0.2) : hovered || selected ? Theme.hover : Color.clear))
            .overlay(RoundedRectangle(cornerRadius: Theme.Radius.sm)
                .strokeBorder(selected ? Theme.accent.opacity(0.5) : .clear, lineWidth: 1))
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .animation(motion.animation(.sidebar, .easeOut(duration: 0.55)), value: flashes)
        .animation(motion.animation(.sidebar, .easeOut(duration: 0.12)), value: hovered)
        .onHover { inside in
            hovered = inside
            if inside { select?() }
        }
        .octetContextMenu(menu)
        .accessibilityElement(children: .contain)
        .accessibilityAddTraits(selected ? .isSelected : [])
        .accessibilityActions {
            if let focus { Button("Jump", action: focus) }
            if let stop { Button("Stop", action: stop) }
            if let markRead { Button(unread ? "Mark read" : "Mark unread", action: markRead) }
            if let copyOutput { Button("Copy output", action: copyOutput) }
            if let openOutput { Button("Open output", action: openOutput) }
            Button(expanded ? "Hide details" : "Show details", action: toggle)
            if let toggleBranch, childCount > 0 {
                Button("\(branchCollapsed ? "Show" : "Hide") \(RuntimeStates.subagentCount(childCount))", action: toggleBranch)
            }
        }
    }

    /// The row's always-visible lines, which open and close it.
    private var summary: some View {
        ZStack(alignment: .topTrailing) {
            Button(action: toggle) {
                HStack(alignment: .top, spacing: Theme.Space.md) {
                    RuntimeGlyph(entry: entry, size: 14, badge: !isShell)
                        .frame(width: TreeConnector.column, height: 20)
                        .treeNode(entry.id, parent: treeParent, order: treeOrder)
                    VStack(alignment: .leading, spacing: Theme.Space.xxs) {
                        HStack(spacing: Theme.Space.sm) {
                            Text(entry.title)
                                .font(entry.kind == .agent ? Theme.Text.bodyMedium : Theme.Text.body)
                                .foregroundStyle(Theme.textPrimary)
                                .lineLimit(1)
                                .truncationMode(.tail)
                            // Beside the title, not in the gutter, where the
                            // tree's lines run.
                            if unread {
                                Circle().fill(Theme.accent).frame(width: 6, height: 6)
                                    .transition(motion.animates(.sidebar) ? .opacity : .identity)
                            }
                            Spacer(minLength: Theme.Space.xs)
                            trailing.opacity(hovered || selected ? 0 : 1)
                        }
                        .frame(minHeight: 20)
                        .animation(motion.animation(.sidebar, .easeOut(duration: 0.3)), value: unread)
                        if !compactRows { secondLine }
                    }
                }
                .padding(.horizontal, Theme.Space.sm)
                .padding(.vertical, Theme.Space.xs)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .help(expanded ? "Hide details" : "Show details")
            .accessibilityLabel(accessibilityText)
            .accessibilityValue(expanded ? "Expanded" : "Collapsed")
            // Hierarchy is the containers' to say, not a "level N".
            .accessibilityHint(expanded ? "Hides the details" : "Shows the details")
            if hovered || selected {
                actions.padding(.trailing, Theme.Space.xs).padding(.top, Theme.Space.xxs)
            }
        }
    }

    private var accessibilityText: String {
        var parts = [entry.title]
        if !isShell, !entry.state.title.isEmpty { parts.append(entry.state.title) }
        if entry.state.bucket == .working, let since = entry.liveSince ?? entry.startedAt {
            parts.append("for " + CompactFormat.elapsed(Date().timeIntervalSince(since)))
        } else if let finished = entry.finishedAt {
            let ago = RuntimeText.ago(Date().timeIntervalSince(finished))
            parts.append(ago == "just now" ? ago : ago + " ago")
        }
        if let todos = entry.todos { parts.append(todos.spoken) }
        if isShell { parts.append(entry.location) }
        if unread { parts.append("unread") }
        return parts.joined(separator: ", ")
    }

    /// The time, the state that needs you, or (with children, under the
    /// pointer) the chevron that folds them: Orca's shared cell.
    @ViewBuilder private var trailing: some View {
        if isShell {
            Text(entry.location).font(Theme.Text.caption).foregroundStyle(Theme.textTertiary).lineLimit(1)
        } else if entry.state.needsYou || entry.state == .failed || entry.state == .planReady || entry.state == .waiting {
            AgentStatePill(state: entry.state, filled: true)
        } else {
            Group {
                if entry.state.bucket == .working, let since = entry.liveSince {
                    RuntimeTimeLabel(date: since, mode: .elapsed)
                } else if entry.kind == .monitor, let label = RuntimeText.label(forDetail: entry.detail) {
                    Text(label + " left")
                } else if let code = entry.exitCode {
                    Text("exit \(code)")
                } else if let finished = entry.finishedAt {
                    RuntimeTimeLabel(date: finished, mode: .ago)
                } else if entry.kind != .agent, let label = RuntimeText.label(forDetail: entry.detail) {
                    Text(label)
                }
            }
            .font(Theme.Text.caption)
            .foregroundStyle(Theme.textTertiary)
            .lineLimit(1)
        }
    }

    /// What it's doing now; what it came to; the error that stopped it. Then
    /// its model and its plan.
    @ViewBuilder private var secondLine: some View {
        switch entry.kind {
        case .agent:
            HStack(spacing: Theme.Space.xs) {
                Group {
                    if entry.state == .failed, let error = RuntimeText.firstLine(of: entry.output) {
                        Text(error).foregroundStyle(Theme.danger)
                    } else if entry.state == .done, let result = RuntimeText.firstLine(of: entry.output) {
                        Text(result)
                    } else if let line = entry.process, !line.isEmpty {
                        AgentActivityText(text: line)
                    }
                }
                .lineLimit(1)
                .truncationMode(.tail)
                .layoutPriority(1)
                if let model = entry.modelName, !model.isEmpty {
                    Text("·")
                    Text(model).lineLimit(1)
                }
                Spacer(minLength: 0)
                if let todos = entry.todos { RuntimeTodoMeter(meter: todos) }
                if childCount > 0, let toggleBranch {
                    Button(action: toggleBranch) {
                        HStack(spacing: Theme.Space.xxs) {
                            Text(RuntimeStates.subagentCount(childCount))
                            OctetIcon(branchCollapsed ? "chevron.right" : "chevron.down", size: 9)
                        }
                        // The activity text gives way, not this.
                        .fixedSize()
                    }
                    .buttonStyle(.plain)
                    .help("\(branchCollapsed ? "Show" : "Hide") \(RuntimeStates.subagentCount(childCount))")
                    .accessibilityLabel("\(branchCollapsed ? "Show" : "Hide") \(RuntimeStates.subagentCount(childCount)) of \(entry.title)")
                }
            }
            .font(Theme.Text.caption)
            .foregroundStyle(Theme.textTertiary)
        case .task, .monitor:
            if let line = RuntimeText.lastLine(of: entry.output) {
                Text(line)
                    .font(Theme.Text.mono(10.5))
                    .foregroundStyle(Theme.textTertiary)
                    .lineLimit(1)
                    .truncationMode(.middle)
            } else if let command = entry.command, !command.isEmpty, command != entry.title {
                Text(command)
                    .font(Theme.Text.mono(10.5))
                    .foregroundStyle(Theme.textTertiary)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
        case .shell:
            EmptyView()
        }
    }

    /// Jump, stop, and ⋯ for the rest, in a pill over the trailing cell.
    private var actions: some View {
        HStack(spacing: 0) {
            if let focus {
                OctetIconButton(icon: "arrow.right.square", help: "Jump to it", compact: true, action: focus)
            }
            if let stop {
                OctetIconButton(icon: "xmark.octagon", help: "Stop", compact: true, tint: Theme.danger, action: stop)
            }
            OctetIconButton(icon: "ellipsis", help: "More", compact: true) {
                OctetContextMenu.present(menu())
            }
        }
        .background(Capsule().fill(Theme.card))
        .overlay(Capsule().strokeBorder(Theme.border, lineWidth: 1))
    }
}

/// A row's indent: one column per level. The edges joining it to the one
/// that started it are drawn over the whole tree (`treeEdges()`).
struct TreeConnector: View {
    let depth: Int
    /// One level's width, the same as the glyph column, so a child's mark
    /// sits one mark further in than its parent's.
    static let column: CGFloat = 18

    var body: some View {
        Color.clear
            .frame(width: Self.column * CGFloat(depth), height: 1)
            .accessibilityHidden(true)
    }
}

/// What a runtime row shows when open: what it was asked or runs, its latest
/// output, and where it belongs. Flat, set off by a hairline at its left.
struct RuntimeDetails: View {
    let entry: RuntimeEntry
    var focus: (() -> Void)? = nil
    var openOutput: (() -> Void)? = nil

    var body: some View {
        VStack(alignment: .leading, spacing: Theme.Space.lg) {
            if let prompt = entry.prompt ?? entry.command, !prompt.isEmpty {
                RuntimeDetailBlock(title: entry.kind == .agent ? "Prompt" : "Command") {
                    ExpandableText(text: prompt, font: entry.kind == .agent ? Theme.Text.body : Theme.Text.mono())
                }
            }
            if let output = entry.output, !output.isEmpty {
                RuntimeDetailBlock(title: "Latest output") {
                    ExpandableText(text: output, font: entry.kind == .agent ? Theme.Text.body : Theme.Text.mono())
                }
            }
            Text(metadata)
                .font(Theme.Text.caption)
                .foregroundStyle(Theme.textTertiary)
                .textSelection(.enabled)
                .lineLimit(3)
            if focus != nil || openOutput != nil {
                HStack(spacing: Theme.Space.sm) {
                    if let focus {
                        OctetButton(title: "Jump", icon: "arrow.right.square", kind: .secondary, compact: true, action: focus)
                    }
                    if let openOutput {
                        OctetButton(title: "Open Output", icon: "arrow.up.left.and.arrow.down.right", kind: .secondary,
                                    compact: true, action: openOutput)
                    }
                }
            }
        }
        .padding(.leading, 32)
        .padding(.trailing, Theme.Space.md)
        .padding(.top, Theme.Space.xxs)
        .padding(.bottom, 10)
    }

    /// Where it is and what it is, joined with " · ".
    private var metadata: String {
        var parts = [entry.location, entry.kind.singular]
        if let started = entry.startedAt ?? entry.liveSince {
            parts.append("started " + started.formatted(date: .omitted, time: .shortened))
        }
        if let model = entry.modelName, !model.isEmpty { parts.append(model) }
        if let pid = entry.pid { parts.append("pid \(pid)") }
        return parts.filter { !$0.isEmpty }.joined(separator: " · ")
    }
}

private struct RuntimeDetailBlock<Content: View>: View {
    let title: String
    let content: Content

    init(title: String, @ViewBuilder content: () -> Content) {
        self.title = title
        self.content = content()
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title.uppercased())
                .font(Theme.Text.micro.weight(.semibold))
                .kerning(0.4)
                .foregroundStyle(Theme.textTertiary)
            content
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.leading, 8)
                .overlay(alignment: .leading) {
                    Rectangle().fill(Theme.divider).frame(width: 2)
                }
        }
    }
}

/// Long prompts and output start at a few lines, so one open row doesn't
/// push the rest of the list away; "Show all" opens the rest.
struct ExpandableText: View {
    let text: String
    let font: Font
    static let collapsedLines = 6
    @ObservedObject private var motion = MotionPreferences.shared
    @State private var showsAll = false

    private var isLong: Bool {
        text.count > 360 || text.reduce(0) { $1 == "\n" ? $0 + 1 : $0 } >= Self.collapsedLines
    }

    /// The opening lines, cut here rather than by a line limit: selectable
    /// text draws every line however few it was given room for, so a long
    /// prompt ran over the sections below it.
    private var collapsed: String {
        let lines = text.split(separator: "\n", omittingEmptySubsequences: false).prefix(Self.collapsedLines)
        var shown = lines.joined(separator: "\n")
        if shown.count > 360 { shown = String(shown.prefix(360)) }
        return shown.count < text.count ? shown.trimmingCharacters(in: .whitespacesAndNewlines) + "…" : shown
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(showsAll ? text : collapsed)
                .font(font)
                .foregroundStyle(Theme.textSecondary)
                .fixedSize(horizontal: false, vertical: true)
                .textSelection(.enabled)
            if isLong {
                Button(showsAll ? "Show less" : "Show all") {
                    motion.perform(.sidebar, .smooth(duration: 0.2)) { showsAll.toggle() }
                }
                .buttonStyle(.plain)
                .font(Theme.Text.captionMedium)
                .foregroundStyle(Theme.accent)
            }
        }
    }
}

struct RuntimeGlyph: View {
    let entry: RuntimeEntry
    let size: CGFloat
    /// The state on the mark's corner, in a cut-out ring (Warp's badge).
    var badge = false

    var body: some View {
        mark
            .overlay(alignment: .bottomTrailing) {
                // Working has no corner mark: its loading line is a smudge at
                // this size, and the ticking time already says it.
                if badge, entry.state != .unknown, entry.state != .working {
                    AgentStateGlyph(state: entry.state, size: 7)
                        .frame(width: 10, height: 10)
                        .background(Circle().fill(Theme.sidebar))
                        .offset(x: 4, y: 3)
                }
            }
            .accessibilityHidden(true)
    }

    @ViewBuilder private var mark: some View {
        if entry.kind == .monitor {
            OctetIcon("eye", size: size).foregroundStyle(entry.tint)
        } else if entry.kind == .task {
            OctetIcon("clock.arrow.circlepath", size: size).foregroundStyle(entry.tint)
        } else if entry.kind == .agent, let brand = AgentBrand.forAgent(entry.agentID) {
            AgentLogo(brand: brand, size: size)
        } else if entry.kind == .agent {
            OctetIcon("tool.agent", size: size).foregroundStyle(entry.tint)
        } else {
            OctetIcon("terminal", size: size).foregroundStyle(entry.tint)
        }
    }
}

/// A root agent's header in the Agents tab: its mark with its rolled-up
/// state on the corner, its name, what it has under it, how full its
/// context is, and the chevron that folds it. A click goes to it.
struct RuntimeGroupHeader: View {
    let group: RuntimeGroup
    let expanded: Bool
    let focus: () -> Void
    let toggle: () -> Void
    let menu: () -> [OctetMenuItem]
    /// The tree node its subagents' edges come from.
    var treeID: String? = nil
    @State private var hovered = false

    var body: some View {
        HStack(spacing: Theme.Space.sm) {
            Button(action: focus) {
                HStack(spacing: Theme.Space.sm) {
                    mark
                        .frame(width: TreeConnector.column, height: 20)
                        .modifier(TreeRoot(id: treeID))
                    Text(group.title)
                        .font(Theme.Text.bodyMedium)
                        .foregroundStyle(Theme.textPrimary)
                        .lineLimit(1)
                        .truncationMode(.tail)
                    Spacer(minLength: Theme.Space.xs)
                    // Open, the tree under it says the same.
                    if !expanded, !group.summary.isEmpty {
                        Text(group.summary)
                            .font(Theme.Text.caption)
                            .foregroundStyle(Theme.textTertiary)
                            .lineLimit(1)
                    }
                    if let fraction = group.contextFraction {
                        ContextRing(fraction: fraction, size: 12)
                            .help("Context \(Int((fraction * 100).rounded()))% used")
                    }
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .help("Go to \(group.title)")
            .accessibilityLabel("\(group.title), \(group.state.title)")
            .accessibilityHint("Goes to it")
            Button(action: toggle) {
                OctetIcon(expanded ? "chevron.down" : "chevron.right", size: 10)
                    .foregroundStyle(Theme.textTertiary)
                    .frame(width: 18, height: 18)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .help(expanded ? "Hide what it started" : "Show what it started")
            .accessibilityLabel(expanded ? "Collapse \(group.title)" : "Expand \(group.title)")
            .accessibilityValue(expanded ? "Expanded" : "Collapsed")
        }
        .padding(.horizontal, Theme.Space.sm)
        .frame(minHeight: 24)
        .background(RoundedRectangle(cornerRadius: Theme.Radius.sm).fill(hovered ? Theme.hover : .clear))
        .onHover { hovered = $0 }
        .octetContextMenu(menu)
        .accessibilityAddTraits(.isHeader)
    }

    /// The vendor's mark, with the rolled-up state on its corner.
    private var mark: some View {
        Group {
            if let brand = AgentBrand.forAgent(group.agentID) {
                AgentLogo(brand: brand, size: 14)
            } else {
                OctetIcon("terminal", size: 13).foregroundStyle(Theme.textTertiary)
            }
        }
        .overlay(alignment: .bottomTrailing) {
            if group.state != .unknown, group.state != .working {
                AgentStateGlyph(state: group.state, size: 7)
                    .frame(width: 10, height: 10)
                    .background(Circle().fill(Theme.sidebar))
                    .offset(x: 4, y: 3)
            }
        }
    }
}

/// Something in the workspace waiting on you, for the Agents tab's strip.
struct RuntimeAttentionItem: Identifiable {
    let id: String
    let title: String
    let agentID: String?
    let state: AgentState
    /// What it wants: the permission, the question, its last words.
    let detail: String?
    let open: () -> Void
    /// Answers it in place, where a message can reach it.
    let send: ((String) -> Void)?
}

/// A needs-you card: what's waiting, what it wants, Open, and Reply… which
/// opens a send field in place.
struct RuntimeAttentionCard: View {
    let item: RuntimeAttentionItem
    let replying: Bool
    let reply: (() -> Void)?
    let send: (String) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: Theme.Space.sm) {
            HStack(spacing: Theme.Space.sm) {
                Group {
                    if let brand = AgentBrand.forAgent(item.agentID) {
                        AgentLogo(brand: brand, size: 14)
                    } else {
                        OctetIcon("tool.agent", size: 14).foregroundStyle(Theme.textTertiary)
                    }
                }
                .overlay(alignment: .bottomTrailing) {
                    AgentStateGlyph(state: item.state, size: 7)
                        .frame(width: 10, height: 10)
                        .background(Circle().fill(Theme.sidebar))
                        .offset(x: 4, y: 3)
                }
                .frame(width: TreeConnector.column, height: 20)
                Text(item.title)
                    .font(Theme.Text.bodyMedium)
                    .foregroundStyle(Theme.textPrimary)
                    .lineLimit(1)
                Spacer(minLength: Theme.Space.xs)
                AgentStatePill(state: item.state, filled: true)
            }
            if let detail = item.detail, !detail.isEmpty {
                Text(detail)
                    .font(Theme.Text.caption)
                    .foregroundStyle(Theme.textSecondary)
                    .lineLimit(2)
                    .fixedSize(horizontal: false, vertical: true)
            }
            HStack(spacing: Theme.Space.sm) {
                OctetButton(title: "Open", icon: "arrow.right.square", kind: .secondary, compact: true, action: item.open)
                if let reply {
                    OctetButton(title: "Reply…", kind: .ghost, compact: true, action: reply)
                }
            }
            if replying {
                AgentSendField(placeholder: "Answer \(item.title)", label: "Reply to \(item.title)", focusOnAppear: true, send: send)
            }
        }
        .padding(Theme.Space.md)
        .background(RoundedRectangle(cornerRadius: Theme.Radius.lg).fill(item.state.color.opacity(0.08)))
        .overlay(RoundedRectangle(cornerRadius: Theme.Radius.lg).strokeBorder(item.state.color.opacity(0.3), lineWidth: 1))
        .accessibilityElement(children: .contain)
        .accessibilityLabel("\(item.title), \(item.state.title)" + (item.detail.map { ", \($0)" } ?? ""))
    }
}

/// A row's whole output, selectable, with Copy: what "Latest output" cuts
/// short in the panel.
struct RuntimeOutputSheet: View {
    let entry: RuntimeEntry
    let close: () -> Void
    @State private var copied = false

    var body: some View {
        let text = entry.output ?? ""
        VStack(spacing: 0) {
            HStack(spacing: Theme.Space.md) {
                RuntimeGlyph(entry: entry, size: 14)
                Text(entry.title).font(Theme.Text.bodyMedium).foregroundStyle(Theme.textPrimary).lineLimit(1)
                Spacer(minLength: Theme.Space.md)
                OctetButton(title: copied ? "Copied" : "Copy", icon: copied ? "checkmark" : "doc.on.doc", kind: .secondary, compact: true) {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(text, forType: .string)
                    ClipboardWatcher.shared.acknowledge()
                    copied = true
                }
                OctetButton(title: "Done", kind: .primary, compact: true, action: close)
                    .keyboardShortcut(.defaultAction)
            }
            .padding(Theme.Space.lg)
            Rectangle().fill(Theme.divider).frame(height: 1)
            ScrollView {
                Text(text)
                    .font(entry.kind == .agent ? Theme.Text.body : Theme.Text.mono())
                    .foregroundStyle(Theme.textSecondary)
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(Theme.Space.lg)
            }
            .octetScrollIndicators()
        }
        .frame(minWidth: 560, idealWidth: 720, minHeight: 360, idealHeight: 520)
        .background(Theme.terminalBackground)
        .onExitCommand(perform: close)
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Output of \(entry.title)")
    }
}

/// A group header's mark as its tree's root, when the tree is open.
private struct TreeRoot: ViewModifier {
    let id: String?

    func body(content: Content) -> some View {
        if let id {
            content.treeNode(id, parent: nil, order: -1)
        } else {
            content
        }
    }
}
