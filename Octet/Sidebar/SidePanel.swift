import SwiftUI

/// One of the right panel's sections. Each has a header with a count and
/// a chevron, and folds away to just the header; which are folded is kept
/// across launches. Plugins' panels are sections too, by plugin id.
enum SidePanelSection: Hashable {
    case files, todos, agents, tasks, monitors, shells
    case plugin(String)

    var title: String {
        switch self {
        case .files: "Files Changed"
        case .todos: "Todos"
        case .agents: "Subagents"
        case .tasks: "Background Tasks"
        case .monitors: "Monitors"
        case .shells: "Shells"
        case .plugin(let id): id
        }
    }

    /// Saved as one string per section.
    var key: String {
        switch self {
        case .files: "files"
        case .todos: "todos"
        case .agents: "agents"
        case .tasks: "tasks"
        case .monitors: "monitors"
        case .shells: "shells"
        case .plugin(let id): "plugin:\(id)"
        }
    }
}

/// Which sections are folded, shared by every window.
@MainActor
final class SidePanelFolds: ObservableObject {
    static let shared = SidePanelFolds()
    private static let key = "octet.sidePanel.folded"

    @Published private(set) var folded: Set<String> = Set(UserDefaults.standard.stringArray(forKey: key) ?? [])

    func isOpen(_ section: SidePanelSection) -> Bool { !folded.contains(section.key) }

    func toggle(_ section: SidePanelSection) {
        set(section, open: !isOpen(section))
    }

    func set(_ section: SidePanelSection, open: Bool) {
        if open { folded.remove(section.key) } else { folded.insert(section.key) }
        UserDefaults.standard.set(Array(folded).sorted(), forKey: Self.key)
    }
}

/// A section's header, with the content below it while it's open.
struct SidePanelSectionView<Content: View, Trailing: View>: View {
    let section: SidePanelSection
    /// In place of the section's own title, for a plugin's panel.
    var title: String?
    let count: Int?
    /// Shown in place of the count, for a section that has more to say
    /// than a number (a branch, a plugin's badge).
    var label: String?
    var labelColor: Color?
    @ViewBuilder var trailing: () -> Trailing
    @ViewBuilder var content: () -> Content
    @ObservedObject private var folds = SidePanelFolds.shared
    @ObservedObject private var motion = MotionPreferences.shared
    @State private var hovered = false

    init(_ section: SidePanelSection, title: String? = nil, count: Int? = nil, label: String? = nil, labelColor: Color? = nil,
         @ViewBuilder trailing: @escaping () -> Trailing, @ViewBuilder content: @escaping () -> Content) {
        self.section = section
        self.title = title
        self.count = count
        self.label = label
        self.labelColor = labelColor
        self.trailing = trailing
        self.content = content
    }

    var body: some View {
        let open = folds.isOpen(section)
        VStack(alignment: .leading, spacing: 0) {
            Button {
                motion.perform(.sidebar) { folds.toggle(section) }
            } label: {
                HStack(spacing: 8) {
                    Text(title ?? section.title)
                        .font(Theme.uiFontMedium)
                        .foregroundStyle(Theme.textPrimary)
                        .lineLimit(1)
                    if let label, !label.isEmpty {
                        Text(label)
                            .font(Theme.captionFont.monospacedDigit())
                            .foregroundStyle(labelColor ?? Theme.textTertiary)
                            .lineLimit(1)
                            .truncationMode(.middle)
                    } else if let count {
                        Text("\(count)")
                            .font(Theme.captionFont.monospacedDigit())
                            .foregroundStyle(Theme.textTertiary)
                            .padding(.horizontal, 6)
                            .frame(minWidth: 20, minHeight: 18)
                            .background(Capsule().fill(Theme.card))
                    }
                    OctetIcon("chevron.right", size: 12)
                        .foregroundStyle(Theme.textTertiary)
                        .rotationEffect(.degrees(open ? 90 : 0))
                    Spacer(minLength: 0)
                    trailing()
                }
                .padding(.horizontal, 12)
                .frame(height: 30)
                .background(hovered ? Theme.hover : Color.clear)
                .clipShape(RoundedRectangle(cornerRadius: Theme.rowRadius))
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .onHover { hovered = $0 }
            .accessibilityLabel("\(title ?? section.title)\(count.map { ", \($0)" } ?? "")")
            .accessibilityValue(open ? "expanded" : "collapsed")
            if open {
                content()
                    .padding(.horizontal, 12)
                    .padding(.top, 4)
                    .padding(.bottom, 10)
            }
        }
        .id(section)
    }
}

extension SidePanelSectionView where Trailing == EmptyView {
    init(_ section: SidePanelSection, title: String? = nil, count: Int? = nil, label: String? = nil, labelColor: Color? = nil,
         @ViewBuilder content: @escaping () -> Content) {
        self.init(section, title: title, count: count, label: label, labelColor: labelColor, trailing: { EmptyView() }, content: content)
    }
}

/// A short list with the rest behind "See all", like the files list on a
/// busy branch.
struct SidePanelMore: View {
    let total: Int
    @Binding var showingAll: Bool
    var shown: Int = 5

    var body: some View {
        if total > shown {
            Button { showingAll.toggle() } label: {
                Text(showingAll ? "Show fewer" : "See all (\(total))")
                    .font(Theme.uiFont)
                    .foregroundStyle(Theme.textTertiary)
            }
            .buttonStyle(.plain)
            .padding(.top, 4)
        }
    }
}

/// The right panel's pages, as the icon tabs across its top.
enum SidePanelTab: String, CaseIterable, Identifiable {
    case overview, git, terminal
    var id: String { rawValue }

    var icon: String {
        switch self {
        case .overview: "list.bullet.rectangle"
        case .git: "git"
        case .terminal: "terminal"
        }
    }

    var title: String {
        switch self {
        case .overview: "Overview"
        case .git: "Git"
        case .terminal: "Terminal"
        }
    }
}

/// The right panel: three pages behind icon tabs. Overview is everything
/// about the tab in front as sections down one page (what was the Runtime
/// and Todos panels, and the plugins' popovers); Git is the old Git panel;
/// Terminal is a shell of the panel's own, in the tab's folder.
struct SidePanel: View {
    @EnvironmentObject private var window: WindowContext
    @ObservedObject var store: SessionStore
    @ObservedObject var ui: UIState
    @ObservedObject private var folds = SidePanelFolds.shared
    @ObservedObject private var motion = MotionPreferences.shared

    static let width: CGFloat = 321

    var body: some View {
        VStack(spacing: 0) {
            tabs
            Rectangle().fill(Theme.divider).frame(height: 1)
            switch ui.sidePanelTab {
            case .overview: overview
            case .git:
                ScrollView {
                    GitPanel(model: window.git, ui: ui).padding(12)
                }
                .scrollIndicators(.hidden)
            case .terminal:
                SidePanelTerminal(store: store, ui: ui)
            }
        }
        .background(Theme.sidebar)
        .onHover { hovering in
            // Pointed at: it's the person's panel now, and stays open.
            if hovering { ui.sidePanelAutoOpened = false }
        }
    }

    private var overview: some View {
        ScrollViewReader { proxy in
            ScrollView {
                // Not lazy: rows open and close in place, which a lazy
                // stack can lose track of and draw as nothing.
                VStack(alignment: .leading, spacing: 6) {
                    RuntimePanel(store: store, ui: ui)
                    TodoPanel(model: window.todos, ui: ui)
                    PluginPanelSections(model: window.pluginPanels)
                }
                .padding(.vertical, 8)
            }
            .scrollIndicators(.hidden)
            .onChange(of: ui.sidePanelJump) { _, jump in
                guard let section = jump?.section else { return }
                folds.set(section, open: true)
                DispatchQueue.main.async {
                    motion.perform(.sidebar, .smooth(duration: 0.25)) { proxy.scrollTo(section, anchor: .top) }
                }
            }
        }
    }

    private var tabs: some View {
        HStack(spacing: 2) {
            ForEach(SidePanelTab.allCases) { tab in
                SidePanelTabButton(tab: tab, selected: ui.sidePanelTab == tab) {
                    motion.perform(.sidebar) { ui.sidePanelTab = tab }
                }
            }
            Spacer()
            Button { ui.sidePanelVisible = false } label: {
                OctetIcon("sidebar.left", size: 14)
                    .scaleEffect(x: -1)
                    .foregroundStyle(Theme.textSecondary)
                    .frame(width: 26, height: 24)
            }
            .buttonStyle(.plain)
            .help("Hide the panel")
        }
        .padding(.horizontal, 8)
        .frame(height: Theme.tabBarHeight)
    }
}

private struct SidePanelTabButton: View {
    let tab: SidePanelTab
    let selected: Bool
    let action: () -> Void
    @State private var hovered = false

    var body: some View {
        Button(action: action) {
            Group {
                if tab == .git {
                    LanguageLogo(language: "git", size: 14)
                } else {
                    OctetIcon(tab.icon, size: 15)
                }
            }
            .foregroundStyle(selected ? Theme.textPrimary : Theme.textSecondary)
            .frame(width: 30, height: 26)
            .background(selected ? Theme.cardSelected : hovered ? Theme.hover : Color.clear)
            .clipShape(RoundedRectangle(cornerRadius: Theme.rowRadius))
        }
        .buttonStyle(.plain)
        .onHover { hovered = $0 }
        .help(tab.title)
        .accessibilityLabel(tab.title)
        .accessibilityAddTraits(selected ? .isSelected : [])
    }
}

/// A shell in the panel, started in the tab's folder the first time the
/// Terminal page is shown and kept for the window's life. Restart starts a
/// fresh one in whatever folder is in front now.
private struct SidePanelTerminal: View {
    @EnvironmentObject private var window: WindowContext
    @ObservedObject var store: SessionStore
    @ObservedObject var ui: UIState
    @StateObject private var anchor = TerminalAnchor()
    @State private var generation = 0
    @State private var exited = false

    private var folder: String {
        window.focusedPaneId.flatMap { store.snapshot.workingDirectory(ofPane: $0) }
            ?? window.focusedWorkspace.flatMap { store.snapshot.directory(ofWorkspace: $0.workspaceId) }
            ?? NSHomeDirectory()
    }

    var body: some View {
        ZStack {
            OctetTerminalView(
                command: Self.shellCommand,
                environment: Self.environment,
                workingDirectory: folder,
                anchor: anchor,
                onExit: { exited = true }
            )
            .id(generation)
            .background(Theme.terminalBackground)
            if exited {
                VStack(spacing: 8) {
                    Text("The shell exited").font(Theme.uiFontMedium).foregroundStyle(Theme.textPrimary)
                    OctetButton(title: "Start Again", kind: .secondary, compact: true) {
                        exited = false
                        generation += 1
                    }
                }
                .padding(16)
                .background(RoundedRectangle(cornerRadius: 8).fill(Theme.chrome))
            }
        }
    }

    /// The person's login shell.
    private static var shellCommand: String {
        if let entry = getpwuid(getuid()), let shell = entry.pointee.pw_shell {
            return String(cString: shell) + " -l"
        }
        return (ProcessInfo.processInfo.environment["SHELL"] ?? "/bin/zsh") + " -l"
    }

    private static var environment: [String: String] {
        var env = TerminalEnvironment.colorCapability
        env["OCTET_SIDE_TERMINAL"] = "1"
        return env
    }
}

/// The tab bar's button for the whole panel.
struct SidePanelButton: View {
    @ObservedObject var ui: UIState
    @State private var hovered = false

    var body: some View {
        Button { ui.sidePanelVisible.toggle() } label: {
            OctetIcon("sidebar.left", size: 14)
                .scaleEffect(x: -1)
                .foregroundStyle(ui.sidePanelVisible ? Theme.textPrimary : Theme.textSecondary)
                .frame(width: 26, height: 24)
                .background(ui.sidePanelVisible ? Theme.cardSelected : hovered ? Theme.hover : Color.clear)
                .clipShape(RoundedRectangle(cornerRadius: Theme.rowRadius))
        }
        .buttonStyle(.plain)
        .onHover { hovered = $0 }
        .help(ui.sidePanelVisible ? "Hide the panel" : "Show the panel: overview, git and a terminal")
        .accessibilityLabel(ui.sidePanelVisible ? "Hide panel" : "Show panel")
    }
}
