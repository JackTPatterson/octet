import AppKit
import SwiftUI

/// The colour and icon for each state. Colour never carries it alone: the
/// icon differs too (spinner, pause, warning, check).
extension RuntimeState {
    var color: Color {
        switch self {
        case .running: Theme.accent
        case .waiting: Color.orange
        case .failed: Theme.danger
        case .done: Color(hex: AgentStateColor.done)
        }
    }

    var icon: String? {
        switch self {
        case .running: nil
        case .waiting: "pause.circle"
        case .failed: "exclamationmark.triangle.fill"
        case .done: "checkmark.circle"
        }
    }
}

/// A state as a small icon and, where it adds something, a word or time.
private struct RuntimeStateBadge: View {
    let entry: RuntimeEntry

    var body: some View {
        let state = entry.state
        HStack(spacing: 4) {
            if let icon = state.icon {
                OctetIcon(icon, size: 12).foregroundStyle(state.color)
            } else if entry.kind != .agent {
                ProgressView().controlSize(.mini).scaleEffect(0.7).frame(width: 12, height: 12)
            }
            if entry.kind == .agent {
                AgentActivityText(text: state == .waiting ? "Needs you" : state.title)
            } else if let since = entry.liveSince, state == .running || state == .waiting {
                ElapsedLabel(since: since)
            } else if let label = RuntimeState.label(forDetail: entry.detail) {
                Text(label)
            }
        }
        .font(Theme.captionFont.monospacedDigit())
        .foregroundStyle(state == .running || state == .done ? Theme.textTertiary : state.color)
        .lineLimit(1)
        .padding(.horizontal, entry.kind == .agent ? 5 : 0)
        .padding(.vertical, entry.kind == .agent ? 2 : 0)
        .background(entry.kind == .agent ? state.color.opacity(0.1) : .clear,
                    in: RoundedRectangle(cornerRadius: 4))
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(state.title)
    }
}

/// One runtime, as a flat row: what it is, where it stands, what it's doing
/// right now. A click opens its details beneath it; the pointer brings its
/// actions (show the tab, stop, ⋯).
struct RuntimeRow: View {
    let entry: RuntimeEntry
    let guide: TreeGuide
    let flashes: Bool
    let expanded: Bool
    let toggle: () -> Void
    let focus: (() -> Void)?
    let stop: (() -> Void)?
    let menu: () -> [OctetMenuItem]
    var childCount: Int = 0
    var branchCollapsed = false
    var toggleBranch: (() -> Void)? = nil
    @ObservedObject private var motion = MotionPreferences.shared
    @State private var hovered = false

    private var compact: Bool { entry.kind == .shell }

    var body: some View {
        HStack(alignment: .top, spacing: 0) {
            if entry.depth > 0 {
                TreeConnector(guide: guide, depth: entry.depth)
            }
            VStack(alignment: .leading, spacing: 0) {
                summary
                if entry.kind == .agent { agentMetadata }
                if expanded {
                    RuntimeDetails(entry: entry)
                        .transition(motion.animates(.sidebar)
                            ? .asymmetric(insertion: .opacity.combined(with: .offset(y: -4)), removal: .opacity)
                            : .identity)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(RoundedRectangle(cornerRadius: Theme.controlRadius)
                .fill(flashes ? entry.tint.opacity(0.2) : hovered ? Theme.hover : Color.clear))
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .animation(motion.animation(.sidebar, .easeOut(duration: 0.55)), value: flashes)
        .animation(motion.animation(.sidebar, .easeOut(duration: 0.12)), value: hovered)
        .onHover { hovered = $0 }
        .octetContextMenu(menu)
    }

    /// The row's always-visible lines, which open and close it.
    private var summary: some View {
        ZStack(alignment: .topTrailing) {
            Button(action: toggle) {
                HStack(alignment: .top, spacing: 8) {
                    RuntimeGlyph(entry: entry, size: 14).frame(width: 18, height: 20)
                    VStack(alignment: .leading, spacing: 2) {
                        HStack(spacing: 6) {
                            Text(entry.title)
                                .font(Theme.uiFontMedium)
                                .foregroundStyle(Theme.textPrimary)
                                .lineLimit(1)
                            if entry.kind != .agent, let modelName = entry.modelName, !modelName.isEmpty {
                                Text(modelName)
                                    .font(Theme.captionFont)
                                    .foregroundStyle(entry.tint)
                                    .lineLimit(1)
                                    .padding(.horizontal, 6)
                                    .frame(height: 16)
                                    .background(Capsule().fill(entry.tint.opacity(0.14)))
                            }
                            Spacer(minLength: 4)
                            if compact {
                                Text(entry.location)
                                    .font(Theme.captionFont)
                                    .foregroundStyle(Theme.textTertiary)
                                    .lineLimit(1)
                                    .opacity(hovered ? 0 : 1)
                            } else {
                                RuntimeStateBadge(entry: entry).opacity(hovered ? 0 : 1)
                            }
                        }
                        .frame(minHeight: 20)
                        detail
                    }
                }
                .padding(.horizontal, 6)
                .padding(.vertical, compact ? 2 : 4)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .help(expanded ? "Hide details" : "Show details")
            .accessibilityLabel("\(entry.title), level \(entry.depth + 1), \(entry.state.title), \(entry.location)")
            .accessibilityValue(expanded ? "Expanded" : "Collapsed")
            .accessibilityHint(expanded ? "Hides the details" : "Shows the details")
            if hovered {
                actions.padding(.trailing, 4).padding(.top, compact ? 0 : 1)
            }
        }
    }

    private var agentMetadata: some View {
        HStack(spacing: 6) {
            if let model = entry.modelName, !model.isEmpty { Text(model).lineLimit(1) }
            if let since = entry.liveSince {
                if entry.modelName != nil { Text("·") }
                ElapsedLabel(since: since)
            }
            Spacer(minLength: 4)
            if childCount > 0, let toggleBranch {
                Button(action: toggleBranch) {
                    HStack(spacing: 4) {
                        Text("\(childCount) subagents")
                        OctetIcon(branchCollapsed ? "chevron.right" : "chevron.down", size: 9)
                    }
                }.buttonStyle(.plain)
                .accessibilityLabel("\(branchCollapsed ? "Show" : "Hide") \(childCount) subagents of \(entry.title)")
            }
        }
        .font(Theme.captionFont).foregroundStyle(Theme.textTertiary)
        .padding(.leading, 32).padding(.trailing, 8).padding(.bottom, 6)
    }

    /// Show the tab, stop, and ⋯ for the rest.
    private var actions: some View {
        HStack(spacing: 0) {
            if let focus {
                OctetIconButton(icon: "arrow.right.square", help: "Show its tab", compact: true, action: focus)
            }
            if let stop {
                OctetIconButton(icon: "xmark.octagon", help: "Stop", compact: true, tint: Theme.danger, action: stop)
            }
            OctetIconButton(icon: "ellipsis", help: "More", compact: true) {
                OctetContextMenu.present(menu())
            }
        }
    }

    /// The lines under the title: what a subagent is doing right now; for a
    /// task or monitor the command in mono and the last line it printed.
    @ViewBuilder
    private var detail: some View {
        switch entry.kind {
        case .agent:
            if let prompt = entry.prompt, !prompt.isEmpty, prompt != entry.title {
                Text(prompt).font(Theme.captionFont).foregroundStyle(Theme.textSecondary).lineLimit(2)
            }
            if let line = entry.process ?? Optional(entry.location), !line.isEmpty {
                AgentActivityText(text: line)
                    .font(Theme.captionFont)
                    .foregroundStyle(Theme.textTertiary)
                    .lineLimit(1)
            }
        case .task, .monitor:
            if let command = entry.command, !command.isEmpty, command != entry.title {
                Text(command)
                    .font(Theme.monoFont)
                    .foregroundStyle(Theme.textSecondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
            if let line = RuntimeState.lastLine(of: entry.output) {
                Text(line)
                    .font(.system(size: 10.5, design: .monospaced))
                    .foregroundStyle(Theme.textTertiary)
                    .lineLimit(1)
                    .truncationMode(.tail)
            }
        case .shell:
            EmptyView()
        }
    }
}

/// The lines that join a subagent to the one that started it: a line down
/// each level with siblings still to come, and an elbow into this row.
private struct TreeConnector: View {
    let guide: TreeGuide
    let depth: Int
    @State private var appeared = false
    @ObservedObject private var motion = MotionPreferences.shared
    /// One level's width, the same as the glyph column, so an elbow ends at
    /// the glyph and a line runs through the parent's glyph centre.
    static let column: CGFloat = 18

    var body: some View {
        Canvas { context, size in
            let column = Self.column
            let elbowY: CGFloat = 14
            let radius: CGFloat = 5
            var path = Path()
            for (level, continues) in guide.verticals.enumerated() where continues {
                let x = column * CGFloat(level) + column / 2
                path.move(to: CGPoint(x: x, y: 0))
                path.addLine(to: CGPoint(x: x, y: size.height))
            }
            let x = column * CGFloat(depth - 1) + column / 2
            let end = column * CGFloat(depth)
            path.move(to: CGPoint(x: x, y: 0))
            if guide.isLast {
                path.addLine(to: CGPoint(x: x, y: elbowY - radius))
                path.addQuadCurve(to: CGPoint(x: x + radius, y: elbowY), control: CGPoint(x: x, y: elbowY))
                path.addLine(to: CGPoint(x: end - 1, y: elbowY))
            } else {
                path.addLine(to: CGPoint(x: x, y: size.height))
                path.move(to: CGPoint(x: x, y: elbowY))
                path.addLine(to: CGPoint(x: end - 1, y: elbowY))
            }
            context.stroke(path, with: .color(Color.white.opacity(0.55)), lineWidth: 1)
        }
        .frame(width: Self.column * CGFloat(depth))
        .frame(maxHeight: .infinity)
        .mask(Rectangle().scaleEffect(y: appeared || !motion.animates(.sidebar) ? 1 : 0, anchor: .top))
        .onAppear { withAnimation(motion.animation(.sidebar, .easeOut(duration: 0.28))) { appeared = true } }
        .accessibilityHidden(true)
    }
}

/// What a runtime row shows when open: what it was asked or runs, its latest
/// output, and where it belongs. Flat, set off by a hairline at its left.
struct RuntimeDetails: View {
    let entry: RuntimeEntry
    @EnvironmentObject private var window: WindowContext

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 7) {
                if entry.state == .running { LoadingLine(width: 16, color: entry.tint) }
                else if let icon = entry.state.icon { OctetIcon(icon, size: 12).foregroundStyle(entry.state.color) }
                Text(entry.process ?? (entry.kind == .monitor ? "Watching" : "Active"))
                    .font(Theme.uiFont)
                    .foregroundStyle(Theme.textPrimary)
                    .lineLimit(1)
            }
            if let prompt = entry.prompt ?? entry.command, !prompt.isEmpty {
                RuntimeDetailBlock(title: entry.kind == .agent ? "Prompt" : "Command") {
                    ExpandableText(text: prompt, font: entry.kind == .agent ? Theme.uiFont : Theme.monoFont)
                }
            }
            if let output = entry.output, !output.isEmpty {
                RuntimeDetailBlock(title: "Latest output") {
                    ExpandableText(text: output, font: entry.kind == .agent ? Theme.uiFont : Theme.monoFont)
                }
            }
            Text([entry.location, entry.kind.singular].joined(separator: " · "))
                .font(Theme.captionFont)
                .foregroundStyle(Theme.textTertiary)
                .textSelection(.enabled)
                .lineLimit(2)
            if let paneId = entry.paneId, entry.kind == .agent {
                OctetButton(title: "Show Tab", kind: .secondary, compact: true) {
                    window.focusAgent(paneId: paneId)
                }
            }
        }
        .padding(.leading, 32)
        .padding(.trailing, 8)
        .padding(.top, 2)
        .padding(.bottom, 10)
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
                .font(Theme.headerFont)
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
                .font(Theme.captionFont.weight(.medium))
                .foregroundStyle(Theme.accent)
            }
        }
    }
}

struct RuntimeGlyph: View {
    let entry: RuntimeEntry
    let size: CGFloat

    var body: some View {
        Group {
            if entry.kind == .monitor {
                Image(systemName: "eye")
                    .font(.system(size: size, weight: .medium))
                    .foregroundStyle(entry.tint)
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
        .accessibilityHidden(true)
    }
}
