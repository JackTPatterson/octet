import SwiftUI

// MARK: - Model

/// The kinds of plane the right panel can show. A plane is one tab in the
/// panel's strip; the "+" picker adds them, after T3 Code's surfaces.
enum PlaneKind: String, Codable, CaseIterable, Identifiable {
    case overview, diff, git, pullRequest, pullRequests, device
    var id: String { rawValue }

    var title: String {
        switch self {
        case .overview: "Overview"
        case .diff: "Diff"
        case .git: "Git"
        case .pullRequest: "Pull Request"
        case .pullRequests: "Pull Requests"
        case .device: "Device"
        }
    }

    var icon: String {
        switch self {
        case .overview: "list.bullet.rectangle"
        case .diff: "doc.diff"
        case .git: "branch"
        case .pullRequest: "pull.request"
        case .pullRequests: "list"
        case .device: "iphone"
        }
    }

    /// The letter that adds one from the picker.
    var key: Character {
        switch self {
        case .overview: "o"
        case .diff: "d"
        case .git: "g"
        case .pullRequest: "p"
        case .pullRequests: "l"
        case .device: "m"
        }
    }

    var detail: String {
        switch self {
        case .overview: "Agents, tasks, todos and plugins for the tab in front"
        case .diff: "What changed, file by file, with notes for the agent"
        case .git: "Changes, commits and worktrees"
        case .pullRequest: "This branch's pull request"
        case .pullRequests: "The repository's open pull requests"
        case .device: "Watch and drive an iOS Simulator or Android Emulator"
        }
    }

    /// Kinds that are one per panel: adding another shows the one there.
    var single: Bool { self != .pullRequest && self != .device }
}

/// One tab in the panel. Pull requests carry their number (none means the
/// branch's own); the rest are one of a kind.
struct Plane: Codable, Identifiable, Equatable {
    let id: String
    let kind: PlaneKind
    var number: Int?
    /// The simulator or emulator a device plane shows; none is its picker.
    var deviceId: String?

    static func make(_ kind: PlaneKind, number: Int? = nil, deviceId: String? = nil) -> Plane {
        switch kind {
        case .pullRequest: Plane(id: "pr:" + (number.map(String.init) ?? "branch"), kind: kind, number: number)
        case .device: Plane(id: "device:" + (deviceId ?? "pick"), kind: kind, deviceId: deviceId)
        default: Plane(id: kind.rawValue, kind: kind)
        }
    }

    static let defaults: [Plane] = [.make(.overview), .make(.git)]
}

/// What a plane shows on its tab beyond its kind: a pull request's number
/// and state, once it's loaded.
struct PlaneBadge: Equatable {
    var title: String
    var tint: Color?
    var help: String?
    /// A mark in place of the kind's, e.g. merged rather than open.
    var icon: String?
}

// MARK: - Strip

/// The panel's strip: a tab per plane, "+" to add one, then the panel's own
/// controls: maximize, the terminal drawer, and hide.
struct PlaneStrip: View {
    @ObservedObject var ui: UIState
    @State private var adding = false

    var body: some View {
        HStack(spacing: 4) {
            ScrollViewReader { proxy in
            ScrollView(.horizontal) {
                HStack(spacing: 4) {
                    ForEach(ui.planes) { plane in
                        PlaneChip(plane: plane, badge: ui.planeBadges[plane.id],
                                  active: ui.activePlane?.id == plane.id, ui: ui)
                            .id(plane.id)
                    }
                    OctetIconButton(icon: "plus", help: "Add a plane") { adding.toggle() }
                        .popover(isPresented: $adding, arrowEdge: .bottom) {
                            PlanePicker(ui: ui) { adding = false }
                                .padding(6)
                                .frame(width: 280)
                                .background(Theme.chrome)
                        }
                }
                .padding(.vertical, 2)
            }
            .scrollIndicators(.never)
            // The plane in front is always in view, as a new one is added.
            .onChange(of: ui.activePlane?.id, initial: true) { _, id in
                guard let id else { return }
                DispatchQueue.main.async {
                    MotionPreferences.shared.perform(.sidebar) { proxy.scrollTo(id, anchor: .trailing) }
                }
            }
            }
            Spacer(minLength: 0)
            if ui.sidePanelVisible {
                OctetIconButton(icon: ui.sidePanelMaximized ? "arrow.down.right.and.arrow.up.left"
                                    : "arrow.up.left.and.arrow.down.right",
                                help: ui.sidePanelMaximized ? "Restore panel size" : "Maximize panel") {
                    MotionPreferences.shared.perform(.sidebar) { ui.sidePanelMaximized.toggle() }
                }
            }
            OctetIconButton(icon: "panel.bottom", help: "Toggle terminal drawer (\(OctetShortcut.terminalDrawer.display))",
                            active: ui.terminalDrawerVisible) {
                MotionPreferences.shared.perform(.sidebar) { ui.terminalDrawerVisible.toggle() }
            }
            OctetIconButton(icon: "sidebar.right", help: "Hide the panel (\(OctetShortcut.togglePanel.display))", active: true) {
                ui.sidePanelVisible = false
            }
        }
        .padding(.leading, 8)
        .padding(.trailing, 6)
        .frame(height: Theme.tabBarHeight)
    }
}

/// One plane's tab: its mark and name, filled while it's in front. The
/// mark turns into a close button under the pointer, as in T3 Code.
private struct PlaneChip: View {
    let plane: Plane
    let badge: PlaneBadge?
    let active: Bool
    @ObservedObject var ui: UIState
    @State private var hovered = false
    @State private var closeHovered = false

    var body: some View {
        HStack(spacing: 3) {
            Button { ui.closePlane(plane.id) } label: {
                ZStack {
                    OctetIcon(badge?.icon ?? plane.kind.icon, size: 12)
                        .foregroundStyle(badge?.tint ?? (active || hovered ? Theme.textPrimary : Theme.textSecondary))
                        .opacity(hovered ? 0 : 1)
                    OctetIcon("xmark", size: 11)
                        .foregroundStyle(Theme.textPrimary)
                        .opacity(hovered ? 1 : 0)
                }
                .frame(width: 16, height: 16)
                .background(RoundedRectangle(cornerRadius: 4).fill(closeHovered ? Theme.cardSelected : .clear))
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .onHover { closeHovered = $0 }
            .help("Close \(title)")
            .accessibilityLabel("Close \(title)")
            Text(title)
                .font(Theme.uiFont)
                .foregroundStyle(active || hovered ? Theme.textPrimary : Theme.textSecondary)
                .lineLimit(1)
                .truncationMode(.tail)
        }
        .padding(.leading, 4)
        .padding(.trailing, 8)
        .frame(height: 24)
        .frame(maxWidth: 150)
        .background(RoundedRectangle(cornerRadius: 6)
            .fill(active ? Theme.cardSelected : hovered ? Theme.hover : .clear))
        .contentShape(Rectangle())
        .onTapGesture { MotionPreferences.shared.perform(.sidebar) { ui.activePlaneId = plane.id } }
        .onHover { hovered = $0 }
        .help(badge?.help ?? title)
        .contextMenu {
            Button("Close") { ui.closePlane(plane.id) }
            Button("Close Others") { ui.closePlanes { $0.id != plane.id } }
                .disabled(ui.planes.count < 2)
            Button("Close to the Right") {
                let after = ui.planes.drop { $0.id != plane.id }.dropFirst().map(\.id)
                ui.closePlanes { after.contains($0.id) }
            }
            .disabled(ui.planes.last?.id == plane.id)
            Divider()
            Button("Close All") { ui.closePlanes { _ in true } }
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel(title)
        .accessibilityAddTraits(active ? [.isButton, .isSelected] : .isButton)
        .accessibilityAction { ui.activePlaneId = plane.id }
        .onDrag { NSItemProvider(object: plane.id as NSString) }
        .onDrop(of: [.text], isTargeted: nil) { providers in
            _ = providers.first?.loadObject(ofClass: NSString.self) { object, _ in
                guard let moved = object as? String else { return }
                DispatchQueue.main.async {
                    MotionPreferences.shared.perform(.sidebar) { ui.movePlane(moved, before: plane.id) }
                }
            }
            return true
        }
    }

    private var title: String {
        badge?.title ?? (plane.kind == .pullRequest ? plane.number.map { "#\($0)" } ?? "Pull Request" : plane.kind.title)
    }
}

// MARK: - Picker

/// The kinds of plane, each with the letter that adds it: the "+" menu,
/// and the panel's launcher when every plane is closed. Letters work while
/// it has focus; arrows move, Return adds.
struct PlanePicker: View {
    @ObservedObject var ui: UIState
    var large = false
    var done: () -> Void = {}
    @State private var highlighted: PlaneKind?
    @FocusState private var focused: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 1) {
            ForEach(PlaneKind.allCases) { kind in
                row(kind)
            }
        }
        .focusable()
        .focusEffectDisabled()
        .focused($focused)
        .onAppear { DispatchQueue.main.async { focused = true } }
        .onKeyPress(.downArrow) { move(1); return .handled }
        .onKeyPress(.upArrow) { move(-1); return .handled }
        .onKeyPress(.return) {
            guard let highlighted else { return .ignored }
            add(highlighted)
            return .handled
        }
        .onKeyPress { press in
            guard press.modifiers.isEmpty || press.modifiers == .shift,
                  let kind = PlaneKind.allCases.first(where: { String($0.key) == press.characters.lowercased() })
            else { return .ignored }
            add(kind)
            return .handled
        }
    }

    private func row(_ kind: PlaneKind) -> some View {
        HStack(spacing: 10) {
            OctetIcon(kind.icon, size: large ? 15 : 14)
                .foregroundStyle(Theme.textSecondary)
                .frame(width: 18)
            VStack(alignment: .leading, spacing: 1) {
                Text(kind.title).font(large ? Theme.uiFontMedium : Theme.uiFont).foregroundStyle(Theme.textPrimary)
                if large {
                    Text(kind.detail).font(Theme.captionFont).foregroundStyle(Theme.textTertiary).lineLimit(1)
                }
            }
            Spacer(minLength: 8)
            Keycap(text: String(kind.key).uppercased())
        }
        .padding(.horizontal, 10)
        .frame(height: large ? 40 : 30)
        .background(RoundedRectangle(cornerRadius: 6).fill(highlighted == kind ? Theme.hover : .clear))
        .contentShape(Rectangle())
        .onHover { if $0 { highlighted = kind } }
        .onTapGesture { add(kind) }
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(.isButton)
        .accessibilityAction { add(kind) }
    }

    private func move(_ delta: Int) {
        let kinds = PlaneKind.allCases
        let current = highlighted.flatMap { kinds.firstIndex(of: $0) } ?? (delta > 0 ? -1 : 0)
        highlighted = kinds[(current + delta + kinds.count) % kinds.count]
    }

    private func add(_ kind: PlaneKind) {
        MotionPreferences.shared.perform(.sidebar) { ui.addPlane(kind) }
        done()
    }
}

/// The panel with no planes: what can be opened, as a list to pick from.
struct PlaneLauncher: View {
    @ObservedObject var ui: UIState

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Open a plane")
                .font(.system(size: 14, weight: .medium))
                .foregroundStyle(Theme.textPrimary)
                .padding(.horizontal, 10)
            PlanePicker(ui: ui, large: true)
        }
        .frame(maxWidth: 320)
        .padding(20)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

/// Stands in for a plane whose view isn't in this build.
struct PlaneUnavailable: View {
    let kind: PlaneKind

    var body: some View {
        VStack(spacing: 8) {
            OctetIcon(kind.icon, size: 22).foregroundStyle(Theme.textTertiary)
            Text("\(kind.title) isn't available yet.")
                .font(Theme.captionFont)
                .foregroundStyle(Theme.textTertiary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}
