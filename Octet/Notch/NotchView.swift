import AppKit
import SwiftUI

// The Octet Notch's SwiftUI: a black island hanging from the top of the
// screen. The panel holding it never resizes; the island's shape animates
// inside it, so there is no window-frame animation to stutter.

/// A black island is black whatever the theme is, so its ink is the Dark
/// theme's, not the window's.
enum NotchStyle {
    static let palette = ThemePalette(theme: .named("Dark"))
    static var primary: Color { palette.color(\.textPrimary) }
    static var secondary: Color { palette.color(\.textSecondary) }
    static var tertiary: Color { palette.color(\.textTertiary) }
    static var accent: Color { palette.color(\.accent) }
    static var danger: Color { palette.color(\.danger) }
    static let amber = Color(hex: "FFC107")
    static let done = Color(hex: AgentStateColor.done)
    static let hover = Color.white.opacity(0.08)
    static let selected = Color.white.opacity(0.14)
    static let divider = Color.white.opacity(0.09)

    static func font(_ size: CGFloat, weight: Font.Weight = .regular) -> Font { Theme.interfaceFont(size, weight: weight) }
    static let caption = Theme.interfaceFont(10.5)
}

/// What the island is doing, per display.
@MainActor
final class NotchViewState: ObservableObject {
    @Published var screen: NotchScreen
    @Published var settings = NotchSettings()
    @Published var phase: NotchMachine.Phase = .collapsed
    @Published var glyphs = NotchGlyphs()
    @Published var tab: NotchTab = .agents
    @Published var peek: NotchPeek?
    /// The open page's natural height, measured.
    @Published var contentHeight: CGFloat = 120

    init(screen: NotchScreen) { self.screen = screen }

    var islandSize: CGSize {
        switch phase {
        case .collapsed: NotchGeometry.collapsedSize(screen, glyphs: glyphs)
        case .peek: NotchGeometry.peekSize(screen, size: settings.size)
        case .expanded: NotchGeometry.expandedSize(screen, size: settings.size, contentHeight: contentHeight + 14)
        }
    }

    var ear: CGFloat {
        switch phase {
        case .collapsed: glyphs.isEmpty ? 0 : NotchGeometry.collapsedEar
        case .peek: 12
        case .expanded: NotchGeometry.expandedEar
        }
    }

    var bottomRadius: CGFloat {
        switch phase {
        case .collapsed: NotchGeometry.collapsedBottomRadius
        case .peek: 18
        case .expanded: NotchGeometry.expandedBottomRadius
        }
    }
}

/// What the island's controls do, supplied by the controller so the views
/// never reach into windows or sessions themselves.
struct NotchActions {
    var open: () -> Void = {}
    var dismiss: () -> Void = {}
    var peekTapped: () -> Void = {}
    var focus: (NotchAgentRow) -> Void = { _ in }
    var stop: (NotchAgentRow) -> Void = { _ in }
    var reply: (NotchAgentRow, String) -> Void = { _, _ in }
    var beginText: () -> Void = {}
    var endText: () -> Void = {}
    var run: (NotchAction) -> Void = { _ in }
    var openFolder: (NotchFolder) -> Void = { _ in }
    var continueWait: (NotchWaitRow) -> Void = { _ in }
    var runCheckIn: (NotchCheckInRow) -> Void = { _ in }
    var skipCheckIn: (NotchCheckInRow) -> Void = { _ in }
    var showAgents: () -> Void = {}
    var settings: () -> Void = {}
}

// MARK: - Shape

/// The island: a flat top that runs out to the screen edge through concave
/// "ears", straight sides, and rounded bottom corners, so it reads as the
/// notch itself growing.
struct NotchShape: Shape {
    var ear: CGFloat
    var bottom: CGFloat

    var animatableData: AnimatablePair<CGFloat, CGFloat> {
        get { .init(ear, bottom) }
        set { ear = newValue.first; bottom = newValue.second }
    }

    func path(in rect: CGRect) -> Path {
        let e = max(0, min(ear, rect.width / 4, rect.height / 2))
        let b = max(0, min(bottom, rect.height / 2, (rect.width - 2 * e) / 2))
        var path = Path()
        path.move(to: CGPoint(x: rect.minX, y: rect.minY))
        path.addQuadCurve(to: CGPoint(x: rect.minX + e, y: rect.minY + e), control: CGPoint(x: rect.minX + e, y: rect.minY))
        path.addLine(to: CGPoint(x: rect.minX + e, y: rect.maxY - b))
        path.addQuadCurve(to: CGPoint(x: rect.minX + e + b, y: rect.maxY), control: CGPoint(x: rect.minX + e, y: rect.maxY))
        path.addLine(to: CGPoint(x: rect.maxX - e - b, y: rect.maxY))
        path.addQuadCurve(to: CGPoint(x: rect.maxX - e, y: rect.maxY - b), control: CGPoint(x: rect.maxX - e, y: rect.maxY))
        path.addLine(to: CGPoint(x: rect.maxX - e, y: rect.minY + e))
        path.addQuadCurve(to: CGPoint(x: rect.maxX, y: rect.minY), control: CGPoint(x: rect.maxX - e, y: rect.minY))
        path.closeSubpath()
        return path
    }
}

// MARK: - Root

struct NotchRootView: View {
    @ObservedObject var state: NotchViewState
    @ObservedObject var model: NotchModel
    @ObservedObject private var motion = MotionPreferences.shared
    let actions: NotchActions

    private var spring: Animation? { motion.animation(.palette, .spring(response: 0.42, dampingFraction: 0.8)) }
    private var fade: Animation? { motion.animation(.palette, .easeOut(duration: 0.16)) }

    var body: some View {
        let size = state.islandSize
        ZStack(alignment: .top) {
            NotchShape(ear: state.ear, bottom: state.bottomRadius).fill(Color.black)
            content
                .padding(.horizontal, state.ear)
                .frame(width: size.width, height: size.height, alignment: .top)
                .clipShape(NotchShape(ear: state.ear, bottom: state.bottomRadius))
        }
        .frame(width: size.width, height: size.height, alignment: .top)
        .shadow(color: .black.opacity(state.phase == .collapsed ? 0 : 0.5), radius: 14, y: 6)
        .animation(spring, value: size)
        .animation(spring, value: state.ear)
        .animation(spring, value: state.bottomRadius)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .environment(\.colorScheme, .dark)
    }

    @ViewBuilder
    private var content: some View {
        switch state.phase {
        case .collapsed:
            NotchCollapsed(state: state)
                .transition(.opacity)
                .accessibilityElement(children: .ignore)
                .accessibilityLabel(state.glyphs.accessibilityLabel)
                .accessibilityHint("Opens the Octet Notch")
                .accessibilityAddTraits(.isButton)
                .accessibilityAction { actions.open() }
                .contentShape(Rectangle())
                .onTapGesture { actions.open() }
        case .peek:
            NotchPeekView(state: state, actions: actions)
                .transition(.opacity)
        case .expanded:
            NotchExpanded(state: state, model: model, actions: actions)
                .transition(.opacity)
                .animation(fade, value: state.tab)
        }
    }
}

// MARK: - Collapsed

private struct NotchCollapsed: View {
    @ObservedObject var state: NotchViewState

    var body: some View {
        let gap = NotchGeometry.cameraGap(state.screen)
        HStack(spacing: 0) {
            HStack(spacing: NotchGlyphs.spacing) {
                ForEach(state.glyphs.left) { NotchGlyphView(glyph: $0) }
            }
            .padding(.trailing, NotchGlyphs.padding)
            .frame(maxWidth: .infinity, alignment: .trailing)
            Spacer().frame(width: gap)
            HStack(spacing: NotchGlyphs.spacing) {
                ForEach(state.glyphs.right) { NotchGlyphView(glyph: $0) }
            }
            .padding(.leading, NotchGlyphs.padding)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .frame(height: NotchGeometry.bandHeight(state.screen) - (state.screen.hasNotch ? 0 : 6))
    }
}

/// The header strip shared by the collapsed island and the peek.
private struct NotchGlyphBand: View {
    @ObservedObject var state: NotchViewState

    var body: some View {
        NotchCollapsed(state: state)
            .frame(height: NotchGeometry.bandHeight(state.screen))
    }
}

struct NotchGlyphView: View {
    let glyph: NotchGlyph
    @ObservedObject private var motion = MotionPreferences.shared

    var body: some View {
        HStack(spacing: 3) {
            mark
            if let text {
                Text(text)
                    .font(NotchStyle.font(10.5, weight: .semibold).monospacedDigit())
                    .foregroundStyle(tint)
                    .lineLimit(1)
                    .fixedSize()
            }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(glyph.label)
    }

    private var text: String? {
        switch glyph {
        case .usage(let warning): "\(warning.percent)%"
        default: glyph.count > 1 ? "\(glyph.count)" : nil
        }
    }

    private var tint: Color {
        switch glyph {
        case .working: NotchStyle.primary
        case .needsYou: NotchStyle.amber
        case .ready: NotchStyle.accent
        case .usage(let warning): warning.level == .critical ? NotchStyle.danger : NotchStyle.amber
        }
    }

    @ViewBuilder
    private var mark: some View {
        switch glyph {
        case .working:
            NotchSpinner(animated: motion.animates(.agentStatus))
        case .needsYou:
            Circle().fill(NotchStyle.amber).frame(width: 8, height: 8).frame(width: 14, height: 14)
        case .ready:
            OctetIcon("clock", size: 13).foregroundStyle(NotchStyle.accent).frame(width: 14, height: 14)
        case .usage(let warning):
            ZStack {
                Circle().stroke(Color.white.opacity(0.18), lineWidth: 2)
                Circle().trim(from: 0, to: max(0.02, Double(warning.percent) / 100))
                    .stroke(tint, style: StrokeStyle(lineWidth: 2, lineCap: .round))
                    .rotationEffect(.degrees(-90))
            }
            .frame(width: 11, height: 11)
            .frame(width: 14, height: 14)
        }
    }
}

/// A quarter ring turning once a second. It animates in the render server,
/// so a spinning glyph costs the app nothing; with motion off it rests.
struct NotchSpinner: View {
    let animated: Bool
    @State private var turned = false

    var body: some View {
        Circle()
            .trim(from: 0, to: 0.7)
            .stroke(NotchStyle.primary, style: StrokeStyle(lineWidth: 2, lineCap: .round))
            .frame(width: 11, height: 11)
            .rotationEffect(.degrees(turned ? 360 : 0))
            .animation(animated ? .linear(duration: 1).repeatForever(autoreverses: false) : nil, value: turned)
            .onAppear { if animated { turned = true } }
            .frame(width: 14, height: 14)
    }
}

// MARK: - Peek

private struct NotchPeekView: View {
    @ObservedObject var state: NotchViewState
    let actions: NotchActions

    var body: some View {
        VStack(spacing: 0) {
            NotchGlyphBand(state: state)
            if let peek = state.peek {
                HStack(spacing: 8) {
                    NotchLogo(vendor: peek.agent, size: 14)
                    Text(peek.line)
                        .font(NotchStyle.font(12, weight: .medium))
                        .foregroundStyle(peek.kind == .needsInput ? NotchStyle.amber : NotchStyle.primary)
                        .lineLimit(1)
                    if peek.more > 0 {
                        Text("+\(peek.more) more").font(NotchStyle.caption).foregroundStyle(NotchStyle.tertiary)
                    }
                    Spacer(minLength: 0)
                    OctetIcon("chevron.right", size: 12).foregroundStyle(NotchStyle.tertiary)
                }
                .padding(.horizontal, 14)
                .frame(height: 34)
                .contentShape(Rectangle())
                .onTapGesture { actions.peekTapped() }
                .accessibilityElement(children: .ignore)
                .accessibilityLabel(peek.line + (peek.more > 0 ? ", and \(peek.more) more" : ""))
                .accessibilityHint("Goes to the agent in Octet")
                .accessibilityAddTraits(.isButton)
            }
        }
    }
}

// MARK: - Expanded

private struct NotchHeightKey: PreferenceKey {
    static var defaultValue: CGFloat = 0
    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) { value = max(value, nextValue()) }
}

private struct NotchExpanded: View {
    @ObservedObject var state: NotchViewState
    @ObservedObject var model: NotchModel
    let actions: NotchActions

    private var tabs: [NotchTab] { state.settings.shownTabs }
    private var tab: NotchTab { tabs.contains(state.tab) ? state.tab : tabs[0] }

    var body: some View {
        let band = NotchGeometry.bandHeight(state.screen)
        VStack(spacing: 0) {
            header(band: band)
            Rectangle().fill(NotchStyle.divider).frame(height: 1)
            ScrollView(.vertical) {
                page
                    .padding(.horizontal, 12)
                    .padding(.vertical, 7)
                    .frame(maxWidth: .infinity, alignment: .topLeading)
                    .background(GeometryReader { Color.clear.preference(key: NotchHeightKey.self, value: $0.size.height) })
            }
            .scrollIndicators(.never)
            .onPreferenceChange(NotchHeightKey.self) { height in
                if abs(height - state.contentHeight) > 0.5 { state.contentHeight = height }
            }
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Octet Notch")
    }

    private func header(band: CGFloat) -> some View {
        let gap = NotchGeometry.cameraGap(state.screen)
        return HStack(spacing: 0) {
            HStack(spacing: 2) {
                ForEach(tabs) { item in
                    NotchTabButton(tab: item, selected: item == tab, badge: item == .agents ? needsCount : 0) {
                        state.tab = item
                    }
                }
            }
            .padding(.leading, 10)
            .frame(maxWidth: .infinity, alignment: .leading)
            Spacer().frame(width: gap)
            HStack(spacing: 2) {
                NotchIconButton(icon: "gearshape", help: "Notch settings", action: actions.settings)
                NotchIconButton(icon: "xmark", help: "Close the notch", action: actions.dismiss)
            }
            .padding(.trailing, 10)
            .frame(maxWidth: .infinity, alignment: .trailing)
        }
        .frame(height: band)
    }

    private var needsCount: Int { model.snapshot.agents.filter { $0.status == .needsInput }.count }

    @ViewBuilder
    private var page: some View {
        switch tab {
        case .agents: NotchAgentsPage(snapshot: model.snapshot, limit: state.settings.size == .compact ? 5 : 7, actions: actions)
        case .now: NotchNowPage(snapshot: model.snapshot, actions: actions)
        case .usage: NotchUsagePage(snapshot: model.snapshot, actions: actions)
        case .actions: NotchActionsPage(snapshot: model.snapshot, actions: actions)
        }
    }
}

// MARK: - Controls

struct NotchIconButton: View {
    let icon: String
    let help: String
    var tint: Color?
    let action: () -> Void
    @State private var hovered = false

    var body: some View {
        Button(action: action) {
            OctetIcon(icon, size: 13)
                .foregroundStyle(tint ?? (hovered ? NotchStyle.primary : NotchStyle.secondary))
                .frame(width: 24, height: 24)
                .background(RoundedRectangle(cornerRadius: 7).fill(hovered ? NotchStyle.hover : .clear))
                .contentShape(Rectangle())
        }
        .buttonStyle(OctetPressStyle())
        .onHover { hovered = $0 }
        .help(help)
        .accessibilityLabel(help)
    }
}

private struct NotchTabButton: View {
    let tab: NotchTab
    let selected: Bool
    let badge: Int
    let action: () -> Void
    @State private var hovered = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: 5) {
                OctetIcon(tab.icon, size: 13)
                if selected { Text(tab.title).font(NotchStyle.font(11.5, weight: .medium)).lineLimit(1) }
                if badge > 0 {
                    Circle().fill(NotchStyle.amber).frame(width: 6, height: 6)
                }
            }
            .foregroundStyle(selected || hovered ? NotchStyle.primary : NotchStyle.secondary)
            .padding(.horizontal, 8)
            .frame(height: 24)
            .background(RoundedRectangle(cornerRadius: 8).fill(selected ? NotchStyle.selected : hovered ? NotchStyle.hover : .clear))
            .contentShape(Rectangle())
        }
        .buttonStyle(OctetPressStyle())
        .onHover { hovered = $0 }
        .help(tab.title)
        .accessibilityLabel(tab.title + (badge > 0 ? ", needs you" : ""))
        .accessibilityAddTraits(selected ? [.isButton, .isSelected] : .isButton)
    }
}

/// A small text button: Continue, Run, Skip.
private struct NotchTextButton: View {
    let title: String
    var prominent = false
    let action: () -> Void
    @State private var hovered = false

    var body: some View {
        Button(action: action) {
            Text(title)
                .font(NotchStyle.font(11, weight: .medium))
                .foregroundStyle(prominent ? Color.black : (hovered ? NotchStyle.primary : NotchStyle.secondary))
                .padding(.horizontal, 9)
                .frame(height: 22)
                .background(RoundedRectangle(cornerRadius: 7)
                    .fill(prominent ? NotchStyle.primary.opacity(hovered ? 1 : 0.92) : (hovered ? NotchStyle.selected : NotchStyle.hover)))
                .contentShape(Rectangle())
        }
        .buttonStyle(OctetPressStyle())
        .onHover { hovered = $0 }
        .accessibilityLabel(title)
    }
}

struct NotchLogo: View {
    let vendor: String?
    var size: CGFloat = 14

    var body: some View {
        Group {
            if let brand = AgentBrand.forAgent(vendor), let asset = brand.logoAssetName {
                Image(asset).resizable().aspectRatio(contentMode: .fit)
                    .foregroundStyle(brand.hueHex.map { Color(hex: $0) } ?? NotchStyle.primary)
            } else {
                OctetIcon("sparkle", size: size).foregroundStyle(NotchStyle.secondary)
            }
        }
        .frame(width: size, height: size)
        .accessibilityHidden(true)
    }
}

private struct NotchSectionTitle: View {
    let text: String
    var body: some View {
        Text(text.uppercased())
            .font(NotchStyle.font(9.5, weight: .semibold))
            .tracking(0.6)
            .foregroundStyle(NotchStyle.tertiary)
            .padding(.horizontal, 6)
            .padding(.top, 4)
            .padding(.bottom, 2)
            .accessibilityAddTraits(.isHeader)
    }
}

private struct NotchEmpty: View {
    let title: String
    var detail: String?
    var body: some View {
        VStack(spacing: 3) {
            Text(title).font(NotchStyle.font(12, weight: .medium)).foregroundStyle(NotchStyle.secondary)
            if let detail { Text(detail).font(NotchStyle.caption).foregroundStyle(NotchStyle.tertiary) }
        }
        .frame(maxWidth: .infinity, minHeight: 72)
    }
}

/// Elapsed time that counts up in place. The timeline only exists while the
/// island is open, so a closed one has no timer.
private struct NotchElapsed: View {
    let since: Date
    var body: some View {
        TimelineView(.periodic(from: .now, by: 1)) { context in
            Text(NotchText.elapsed(from: since, now: context.date))
                .font(NotchStyle.caption.monospacedDigit())
                .foregroundStyle(NotchStyle.tertiary)
        }
    }
}

// MARK: - Agents

private struct NotchAgentsPage: View {
    let snapshot: NotchSnapshot
    let limit: Int
    let actions: NotchActions

    var body: some View {
        let shown = NotchAgentOrdering.visible(snapshot.agents, limit: limit)
        if shown.shown.isEmpty {
            NotchEmpty(title: "No agents yet", detail: "Start one from Actions, or in a terminal tab.")
        } else {
            VStack(alignment: .leading, spacing: 1) {
                ForEach(shown.shown) { NotchAgentRowView(row: $0, actions: actions) }
                if shown.hidden > 0 {
                    Button(action: actions.showAgents) {
                        Text("\(shown.hidden) more in Octet")
                            .font(NotchStyle.caption)
                            .foregroundStyle(NotchStyle.tertiary)
                            .padding(.horizontal, 6).padding(.vertical, 5)
                    }
                    .buttonStyle(.plain)
                }
            }
        }
    }
}

private struct NotchAgentRowView: View {
    let row: NotchAgentRow
    let actions: NotchActions
    @State private var hovered = false
    @State private var replying = false
    @State private var reply = ""
    @FocusState private var replyFocused: Bool
    @ObservedObject private var motion = MotionPreferences.shared

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 9) {
                marker.frame(width: 14)
                NotchLogo(vendor: row.vendor, size: 15)
                VStack(alignment: .leading, spacing: 1) {
                    Text(row.title)
                        .font(NotchStyle.font(12, weight: .medium))
                        .foregroundStyle(NotchStyle.primary)
                        .lineLimit(1)
                    if let subtitle {
                        Text(subtitle).font(NotchStyle.caption).foregroundStyle(NotchStyle.tertiary).lineLimit(1)
                    }
                }
                Spacer(minLength: 8)
                trailing
            }
            .padding(.horizontal, 6)
            .frame(height: 38)
            .contentShape(Rectangle())
            .onTapGesture { actions.focus(row) }
            if replying { replyField }
        }
        .background(RoundedRectangle(cornerRadius: 8)
            .fill(row.status == .needsInput ? NotchStyle.amber.opacity(hovered ? 0.16 : 0.10) : (hovered ? NotchStyle.hover : .clear)))
        .onHover { hovered = $0 }
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(row.title), \(statusWord)" + (subtitle.map { ", \($0)" } ?? ""))
        .accessibilityHint("Goes to it in Octet")
        .accessibilityAddTraits(.isButton)
        .accessibilityAction { actions.focus(row) }
    }

    private var statusWord: String {
        switch row.status {
        case .needsInput: "needs you"
        case .working: "working"
        case .done: "done"
        }
    }

    private var subtitle: String? {
        let parts = [row.workspace, row.detail].compactMap { $0 }.filter { !$0.isEmpty }
        return parts.isEmpty ? nil : parts.joined(separator: " · ")
    }

    @ViewBuilder
    private var marker: some View {
        switch row.status {
        case .needsInput: Circle().fill(NotchStyle.amber).frame(width: 8, height: 8)
        case .working: NotchSpinner(animated: motion.animates(.agentStatus))
        case .done: OctetIcon("checkmark", size: 12).foregroundStyle(NotchStyle.done)
        }
    }

    @ViewBuilder
    private var trailing: some View {
        if hovered {
            HStack(spacing: 2) {
                if row.canReply {
                    NotchTextButton(title: replying ? "Cancel" : "Reply") { toggleReply() }
                }
                if row.canStop {
                    NotchIconButton(icon: "square", help: "Stop \(row.title)", tint: NotchStyle.danger) { actions.stop(row) }
                }
                NotchTextButton(title: "Open", prominent: row.status == .needsInput) { actions.focus(row) }
            }
        } else if row.status != .done, let since = row.since {
            VStack(alignment: .trailing, spacing: 1) {
                if row.status == .needsInput {
                    Text("needs you").font(NotchStyle.caption).foregroundStyle(NotchStyle.amber)
                }
                NotchElapsed(since: since)
            }
        } else if row.status == .needsInput {
            Text("needs you").font(NotchStyle.caption).foregroundStyle(NotchStyle.amber)
        }
    }

    private var replyField: some View {
        HStack(spacing: 6) {
            TextField("", text: $reply, prompt: Text("Reply to \(row.title)").foregroundColor(Color.white.opacity(0.38)))
                .textFieldStyle(.plain)
                .font(NotchStyle.font(12))
                .foregroundStyle(NotchStyle.primary)
                .focused($replyFocused)
                .onSubmit(send)
                .padding(.horizontal, 9)
                .frame(height: 26)
                .background(RoundedRectangle(cornerRadius: 7).fill(Color.white.opacity(0.08)))
                .overlay(RoundedRectangle(cornerRadius: 7).strokeBorder(replyFocused ? NotchStyle.accent.opacity(0.7) : NotchStyle.divider))
            NotchTextButton(title: "Send", prominent: true, action: send)
                .disabled(reply.trimmingCharacters(in: .whitespaces).isEmpty)
        }
        .padding(.horizontal, 6)
        .padding(.bottom, 6)
        .onChange(of: replyFocused) { _, focused in focused ? actions.beginText() : actions.endText() }
    }

    private func toggleReply() {
        replying.toggle()
        if replying {
            actions.beginText()
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.08) { replyFocused = true }
        } else {
            replyFocused = false
            actions.endText()
        }
    }

    private func send() {
        let text = reply.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return }
        actions.reply(row, text)
        reply = ""
        replying = false
        replyFocused = false
        actions.endText()
    }
}

// MARK: - Now

private struct NotchNowPage: View {
    let snapshot: NotchSnapshot
    let actions: NotchActions

    var body: some View {
        if snapshot.runtimes.isEmpty && snapshot.readyWaits.isEmpty && snapshot.checkIns.isEmpty {
            NotchEmpty(title: "Nothing in the background",
                       detail: snapshot.waitingCount > 0 ? "\(snapshot.waitingCount) waiting for something to happen" : nil)
        } else {
            VStack(alignment: .leading, spacing: 2) {
                if !snapshot.runtimes.isEmpty {
                    NotchSectionTitle(text: "Running")
                    ForEach(snapshot.runtimes) { runtime in
                        HStack(spacing: 8) {
                            Text(runtime.kind)
                                .font(NotchStyle.font(9.5, weight: .semibold))
                                .foregroundStyle(NotchStyle.secondary)
                                .padding(.horizontal, 6).padding(.vertical, 2)
                                .background(Capsule().fill(NotchStyle.hover))
                            Text(runtime.title).font(NotchStyle.font(12)).foregroundStyle(NotchStyle.primary).lineLimit(1)
                            Spacer(minLength: 6)
                            if let since = runtime.since { NotchElapsed(since: since) }
                        }
                        .padding(.horizontal, 6).frame(height: 28)
                    }
                }
                if !snapshot.readyWaits.isEmpty {
                    NotchSectionTitle(text: "Ready")
                    ForEach(snapshot.readyWaits) { wait in
                        NotchRowWithActions(title: wait.title, detail: wait.next, tint: NotchStyle.accent) {
                            NotchTextButton(title: "Continue", prominent: true) { actions.continueWait(wait) }
                        }
                    }
                }
                if !snapshot.checkIns.isEmpty {
                    NotchSectionTitle(text: "Check-ins")
                    ForEach(snapshot.checkIns) { checkIn in
                        NotchRowWithActions(title: checkIn.title,
                                            detail: checkIn.due ? "Due now" : "\(checkIn.schedule) · next " + CheckInInfo.dayTime(checkIn.nextAt),
                                            tint: checkIn.due ? NotchStyle.amber : NotchStyle.tertiary) {
                            if checkIn.canSkip { NotchTextButton(title: "Skip") { actions.skipCheckIn(checkIn) } }
                            NotchTextButton(title: "Run", prominent: checkIn.due) { actions.runCheckIn(checkIn) }
                        }
                    }
                }
                if snapshot.waitingCount > 0 {
                    Text("\(snapshot.waitingCount) more waiting for something to happen")
                        .font(NotchStyle.caption).foregroundStyle(NotchStyle.tertiary)
                        .padding(.horizontal, 6).padding(.top, 4)
                }
            }
        }
    }
}

private struct NotchRowWithActions<Buttons: View>: View {
    let title: String
    let detail: String
    let tint: Color
    @ViewBuilder let buttons: Buttons
    @State private var hovered = false

    var body: some View {
        HStack(spacing: 9) {
            Circle().fill(tint).frame(width: 7, height: 7).frame(width: 14)
            VStack(alignment: .leading, spacing: 1) {
                Text(title).font(NotchStyle.font(12, weight: .medium)).foregroundStyle(NotchStyle.primary).lineLimit(1)
                Text(detail).font(NotchStyle.caption).foregroundStyle(NotchStyle.tertiary).lineLimit(1)
            }
            Spacer(minLength: 8)
            HStack(spacing: 4) { buttons }
        }
        .padding(.horizontal, 6)
        .frame(height: 38)
        .background(RoundedRectangle(cornerRadius: 8).fill(hovered ? NotchStyle.hover : .clear))
        .onHover { hovered = $0 }
        .accessibilityElement(children: .contain)
    }
}

// MARK: - Usage

private struct NotchUsagePage: View {
    let snapshot: NotchSnapshot
    let actions: NotchActions

    var body: some View {
        if snapshot.usage.isEmpty {
            NotchEmpty(title: "No usage to show", detail: "Allowances appear once an agent reports them.")
        } else {
            HStack(alignment: .top, spacing: 0) {
                ForEach(Array(snapshot.usage.enumerated()), id: \.element.id) { index, row in
                    if index > 0 { Rectangle().fill(NotchStyle.divider).frame(width: 1).padding(.vertical, 4) }
                    NotchUsageColumn(row: row, actions: actions)
                }
            }
        }
    }
}

private struct NotchUsageColumn: View {
    let row: NotchUsageRow
    let actions: NotchActions

    var body: some View {
        VStack(alignment: .leading, spacing: 7) {
            HStack(spacing: 6) {
                NotchLogo(vendor: row.agent, size: 14)
                Text(row.name).font(NotchStyle.font(12, weight: .medium)).foregroundStyle(NotchStyle.primary)
                if let plan = row.plan { Text(plan).font(NotchStyle.caption).foregroundStyle(NotchStyle.tertiary) }
            }
            if let note = row.note {
                Text(note).font(NotchStyle.caption).foregroundStyle(NotchStyle.tertiary)
            }
            ForEach(row.windows, id: \.name) { window in
                HStack(spacing: 7) {
                    ZStack {
                        Circle().stroke(Color.white.opacity(0.16), lineWidth: 2.5)
                        Circle().trim(from: 0, to: max(0.02, min(1, window.used)))
                            .stroke(color(window.used, agent: row.agent), style: StrokeStyle(lineWidth: 2.5, lineCap: .round))
                            .rotationEffect(.degrees(-90))
                    }
                    .frame(width: 18, height: 18)
                    VStack(alignment: .leading, spacing: 0) {
                        HStack(spacing: 5) {
                            Text("\(Int((min(1, max(0, window.used)) * 100).rounded()))%")
                                .font(NotchStyle.font(12, weight: .semibold).monospacedDigit())
                                .foregroundStyle(window.used >= 0.7 ? color(window.used, agent: row.agent) : NotchStyle.primary)
                            Text(window.title).font(NotchStyle.caption).foregroundStyle(NotchStyle.secondary)
                        }
                        if let reset = UsageWindow(name: window.name, used: window.used, resetsAt: window.resetsAt).resetsIn(at: Date()) {
                            Text(reset).font(NotchStyle.caption).foregroundStyle(NotchStyle.tertiary)
                        }
                    }
                }
                .accessibilityElement(children: .combine)
            }
        }
        .padding(.horizontal, 10)
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func color(_ used: Double, agent: String) -> Color {
        if used >= 0.9 { return NotchStyle.danger }
        if used >= 0.7 { return NotchStyle.amber }
        return UsagePalette.color(agent)
    }
}

// MARK: - Actions

private struct NotchActionsPage: View {
    let snapshot: NotchSnapshot
    let actions: NotchActions

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 6), count: 4), spacing: 6) {
                ForEach(NotchAction.allCases) { action in
                    NotchActionTile(action: action) { actions.run(action) }
                }
            }
            if !snapshot.folders.isEmpty {
                NotchSectionTitle(text: "Recent folders")
                ScrollView(.horizontal) {
                    HStack(spacing: 6) {
                        ForEach(snapshot.folders.prefix(5)) { folder in
                            NotchFolderChip(folder: folder) { actions.openFolder(folder) }
                        }
                    }
                }
                .scrollIndicators(.never)
            }
        }
    }
}

private struct NotchActionTile: View {
    let action: NotchAction
    let run: () -> Void
    @State private var hovered = false

    var body: some View {
        Button(action: run) {
            VStack(spacing: 5) {
                Group {
                    if let agent = action.agent { NotchLogo(vendor: agent, size: 17) }
                    else { OctetIcon(action.icon, size: 17).foregroundStyle(hovered ? NotchStyle.primary : NotchStyle.secondary) }
                }
                .frame(height: 20)
                Text(action.title)
                    .font(NotchStyle.font(10.5, weight: .medium))
                    .foregroundStyle(hovered ? NotchStyle.primary : NotchStyle.secondary)
                    .lineLimit(1)
            }
            .frame(maxWidth: .infinity)
            .frame(height: 50)
            .background(RoundedRectangle(cornerRadius: 9).fill(hovered ? NotchStyle.selected : NotchStyle.hover.opacity(0.6)))
            .contentShape(Rectangle())
        }
        .buttonStyle(OctetPressStyle())
        .onHover { hovered = $0 }
        .help(action.detail)
        .accessibilityLabel(action.title)
        .accessibilityHint(action.detail)
    }
}

private struct NotchFolderChip: View {
    let folder: NotchFolder
    let action: () -> Void
    @State private var hovered = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: 6) {
                OctetIcon("folder", size: 13).foregroundStyle(NotchStyle.secondary)
                Text(folder.name).font(NotchStyle.font(11.5, weight: .medium)).foregroundStyle(hovered ? NotchStyle.primary : NotchStyle.secondary).lineLimit(1)
            }
            .padding(.horizontal, 10)
            .frame(height: 26)
            .background(RoundedRectangle(cornerRadius: 8).fill(hovered ? NotchStyle.selected : NotchStyle.hover))
            .contentShape(Rectangle())
        }
        .buttonStyle(OctetPressStyle())
        .onHover { hovered = $0 }
        .help("Open \(abbreviateHome(folder.path)) in Octet")
        .accessibilityLabel("Open \(folder.name)")
    }
}
