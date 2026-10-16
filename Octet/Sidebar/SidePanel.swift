import SwiftUI

/// One of the right panel's sections. Each has a header with a count and
/// a chevron, and folds away to just the header; which are folded is kept
/// across launches. Plugins' panels are sections too, by plugin id.
enum SidePanelSection: Hashable {
    case files, todos, agents, tasks, monitors, shells, setup
    case plugin(String)

    var title: String {
        switch self {
        case .files: "Files Changed"
        case .todos: "Todos"
        case .agents: "Subagents"
        case .tasks: "Background Tasks"
        case .monitors: "Monitors"
        case .shells: "Shells"
        case .setup: "Agent Setup"
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
        case .setup: "setup"
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

/// The right panel: a strip of planes (tabs added with "+", after T3 Code's
/// surfaces) over the one in front. Overview is everything about the tab in
/// front as sections down one page; Git is the Git panel; pull requests come
/// from GitHub. Every plane stays alive behind the one showing, so a pull
/// request keeps what it loaded and where it was scrolled.
struct SidePanel: View {
    @EnvironmentObject private var window: WindowContext
    @ObservedObject var store: SessionStore
    @ObservedObject var ui: UIState
    @ObservedObject private var folds = SidePanelFolds.shared
    @ObservedObject private var motion = MotionPreferences.shared

    /// Wide enough for a pull request or a device, as T3 Code's panel opens.
    static let width: CGFloat = 420

    var body: some View {
        VStack(spacing: 0) {
            PlaneStrip(ui: ui)
            Rectangle().fill(Theme.divider).frame(height: 1)
            ZStack {
                if ui.planes.isEmpty {
                    PlaneLauncher(ui: ui)
                }
                ForEach(ui.planes) { plane in
                    let shown = plane.id == ui.activePlane?.id
                    planeView(plane)
                        .opacity(shown ? 1 : 0)
                        .allowsHitTesting(shown)
                        .accessibilityHidden(!shown)
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .background(Theme.sidebar)
        .onHover { hovering in
            // Pointed at: it's the person's panel now, and stays open.
            if hovering { ui.sidePanelAutoOpened = false }
        }
    }

    @ViewBuilder
    private func planeView(_ plane: Plane) -> some View {
        switch plane.kind {
        case .overview: overview
        case .git:
            ScrollView {
                GitPanel(model: window.git, ui: ui).padding(12)
            }
            .scrollIndicators(.hidden)
        case .diff: DiffPlane(store: store, ui: ui)
        case .files: FilesPlane(ui: ui, directory: planeDirectory)
        case .browser: BrowserPlane(ui: ui)
        case .pullRequest:
            if let directory = planeDirectory {
                PullRequestPlane(directory: directory, number: plane.number,
                                 askAgent: { askAgent($0, in: directory) },
                                 onSummary: { number, tone, title in
                                     let badge = PlaneBadge(title: "#\(number)", tint: tone.color,
                                                            help: "#\(number) \(title)", icon: tone.icon)
                                     if ui.planeBadges[plane.id] != badge { ui.planeBadges[plane.id] = badge }
                                 })
            } else {
                PlaneMessage(icon: "pull.request", title: "No project in front",
                             detail: "Open a tab in a repository to see its pull request.")
            }
        case .pullRequests:
            if let directory = planeDirectory {
                PullRequestListPlane(directory: directory) { number in
                    MotionPreferences.shared.perform(.sidebar) { ui.showPlane(.pullRequest, number: number) }
                }
            } else {
                PlaneMessage(icon: "list", title: "No project in front",
                             detail: "Open a tab in a repository to see its pull requests.")
            }
        case .device:
            DevicePlane(deviceId: plane.deviceId,
                        visible: ui.sidePanelVisible && ui.activePlane?.id == plane.id,
                        onOpen: { device in
                            ui.setPlaneDevice(plane.id, deviceId: device.id)
                            let badge = PlaneBadge(title: device.name,
                                                   help: [device.name, device.version].filter { !$0.isEmpty }.joined(separator: " · "),
                                                   icon: device.platform == .android ? "device.android"
                                                       : device.isTablet ? "device.ipad" : "device.iphone")
                            if ui.planeBadges[plane.id] != badge { ui.planeBadges[plane.id] = badge }
                        },
                        askAgent: { prompt in
                            if let directory = planeDirectory { askAgent(prompt, in: directory) }
                            else { ToastCenter.shared.info("No agent here to ask", detail: "Start an agent in a project, then try again.") }
                        })
        }
    }

    /// The project planes look at: the pane in front's.
    private var planeDirectory: String? {
        #if DEBUG
        // Verification hook: a project to show without a pane in it.
        if let forced = ProcessInfo.processInfo.environment["OCTET_PLANE_DIRECTORY"] { return forced }
        #endif
        return window.focusedDirectory
    }

    /// Sends a prompt to the agent working in `directory`'s project, the
    /// one in front first; says so when there's none.
    private func askAgent(_ prompt: String, in directory: String) {
        guard let agent = DiffReviewView.agents(in: store, directory: directory).first else {
            ToastCenter.shared.info("No agent here to ask", detail: "Start an agent in this project, then try again.")
            return
        }
        store.broadcast(prompt, to: [Broadcast.Target(paneId: agent.paneId,
                                                      name: DiffReviewView.name(agent, in: store), isAgent: true)])
    }

    private var overview: some View {
        ScrollViewReader { proxy in
            ScrollView {
                // Not lazy: rows open and close in place, which a lazy
                // stack can lose track of and draw as nothing.
                VStack(alignment: .leading, spacing: 6) {
                    RuntimePanel(store: store, ui: ui)
                    TodoPanel(model: window.todos, ui: ui)
                    ProjectAgentSection(model: window.projectAgent)
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
}

/// The tab bar's controls for the panel and the terminal drawer, shown
/// while the panel is closed; while it's open its own strip has them, as in
/// T3 Code.
struct SidePanelButton: View {
    @ObservedObject var ui: UIState

    var body: some View {
        if !ui.sidePanelVisible {
            HStack(spacing: 2) {
                OctetIconButton(icon: "panel.bottom",
                                help: "Toggle terminal drawer (\(OctetShortcut.terminalDrawer.display))",
                                active: ui.terminalDrawerVisible) {
                    MotionPreferences.shared.perform(.sidebar) { ui.terminalDrawerVisible.toggle() }
                }
                OctetIconButton(icon: "sidebar.right", help: "Show the panel (\(OctetShortcut.togglePanel.display))") {
                    ui.sidePanelVisible = true
                }
                .accessibilityLabel("Show panel")
            }
        }
    }
}
