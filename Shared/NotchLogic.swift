import CoreGraphics
import Foundation

// The pure decisions behind the Octet Notch: how big the island is and where
// it sits for a screen's notch (or the lack of one), which screens show it,
// what the collapsed glyphs say, how the agent rows are ordered, when a
// finished agent earns a peek, and the hover/click state machine with its
// grace delays. Kept apart from the panel and the views so they can be tested.

// MARK: - Settings

/// The pages the expanded island can show.
enum NotchTab: String, Codable, CaseIterable, Identifiable {
    case agents, now, usage, actions

    var id: String { rawValue }

    var title: String {
        switch self {
        case .agents: "Agents"
        case .now: "Now"
        case .usage: "Usage"
        case .actions: "Actions"
        }
    }

    var icon: String {
        switch self {
        case .agents: "sparkle"
        case .now: "clock"
        case .usage: "gauge"
        case .actions: "plus.square"
        }
    }
}

struct NotchSettings: Codable, Equatable {
    enum Expand: String, Codable, CaseIterable {
        case hover, click
        var title: String { self == .hover ? "Hover" : "Click" }
    }

    enum Displays: String, Codable, CaseIterable {
        case main, pointer, all
        var title: String {
            switch self {
            case .main: "Main display"
            case .pointer: "Display with the pointer"
            case .all: "All displays"
            }
        }
    }

    enum Size: String, Codable, CaseIterable {
        case compact, regular
        var title: String { self == .compact ? "Compact" : "Regular" }
    }

    var enabled = false
    var expand: Expand = .hover
    var displays: Displays = .main
    /// Displays without a notch get a floating pill at the top centre.
    var showWithoutNotch = true
    var peekOnEvents = true
    var showInFullScreen = false
    var haptic = true
    var size: Size = .regular
    var tabs: [NotchTab] = NotchTab.allCases

    init() {}

    /// Missing keys fall back to defaults, so settings saved before the
    /// notch existed (or by a newer build) never fail to load.
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: Key.self)
        let d = NotchSettings()
        enabled = (try? c.decodeIfPresent(Bool.self, forKey: .enabled)) ?? d.enabled
        expand = (try? c.decodeIfPresent(Expand.self, forKey: .expand)) ?? d.expand
        displays = (try? c.decodeIfPresent(Displays.self, forKey: .displays)) ?? d.displays
        showWithoutNotch = (try? c.decodeIfPresent(Bool.self, forKey: .showWithoutNotch)) ?? d.showWithoutNotch
        peekOnEvents = (try? c.decodeIfPresent(Bool.self, forKey: .peekOnEvents)) ?? d.peekOnEvents
        showInFullScreen = (try? c.decodeIfPresent(Bool.self, forKey: .showInFullScreen)) ?? d.showInFullScreen
        haptic = (try? c.decodeIfPresent(Bool.self, forKey: .haptic)) ?? d.haptic
        size = (try? c.decodeIfPresent(Size.self, forKey: .size)) ?? d.size
        let names = (try? c.decodeIfPresent([String].self, forKey: .tabs)) ?? d.tabs.map(\.rawValue)
        tabs = names.compactMap(NotchTab.init(rawValue:))
    }

    private enum Key: String, CodingKey {
        case enabled, expand, displays, showWithoutNotch, peekOnEvents, showInFullScreen, haptic, size, tabs
    }

    /// The tabs to show, in the island's own order, never none: a notch with
    /// every page switched off would have nothing to open.
    var shownTabs: [NotchTab] {
        let wanted = NotchTab.allCases.filter(tabs.contains)
        return wanted.isEmpty ? [.agents] : wanted
    }

    mutating func set(_ tab: NotchTab, shown: Bool) {
        var next = Set(tabs)
        if shown { next.insert(tab) } else { next.remove(tab) }
        tabs = NotchTab.allCases.filter(next.contains)
    }
}

// MARK: - Geometry

/// What the notch needs to know about one display, copied out of NSScreen so
/// the maths can be tested. Coordinates are AppKit's: global, y up.
struct NotchScreen: Equatable {
    var id: Int
    var frame: CGRect
    /// `safeAreaInsets.top`: the notch's height, 0 on a display without one.
    var safeAreaTop: CGFloat
    /// Widths of `auxiliaryTopLeftArea` / `auxiliaryTopRightArea`, the menu
    /// bar either side of the notch; 0 when the display reports none.
    var auxLeftWidth: CGFloat = 0
    var auxRightWidth: CGFloat = 0

    var hasNotch: Bool { safeAreaTop > 0 }
}

enum NotchGeometry {
    /// A notch whose side areas aren't reported is about this wide.
    static let fallbackNotchWidth: CGFloat = 185
    /// The idle pill on a display without a notch.
    static let pillSize = CGSize(width: 132, height: 6)
    /// Height of the header band on a display without a notch.
    static let flatBandHeight: CGFloat = 30

    static let regularWidth: CGFloat = 620
    static let compactWidth: CGFloat = 520
    static let regularMaxHeight: CGFloat = 260
    static let compactMaxHeight: CGFloat = 224
    /// The least an open island shows below its header, so a one-row page
    /// doesn't squash.
    static let minContentHeight: CGFloat = 92

    /// Ears: the concave corners where the island meets the screen's top
    /// edge, and the rounded bottom.
    static let collapsedEar: CGFloat = 6
    static let collapsedBottomRadius: CGFloat = 10
    static let expandedEar: CGFloat = 18
    static let expandedBottomRadius: CGFloat = 24

    /// The panel's window level: the main menu is 24 and status items 25, so
    /// 27 sits over both and clicks on the island never reach them.
    static let panelLevel = 27
    static let menuBarLevel = 24
    static let statusItemLevel = 25

    /// Room around the island inside the panel for its shadow.
    static let shadowInset: CGFloat = 20

    /// The hardware notch's size, or the idle pill's on a display without one.
    static func notchSize(_ screen: NotchScreen) -> CGSize {
        guard screen.hasNotch else { return pillSize }
        let sides = screen.auxLeftWidth + screen.auxRightWidth
        let width = sides > 0 ? screen.frame.width - sides : fallbackNotchWidth
        // A nonsense report (sides wider than the screen) is no report.
        return CGSize(width: width > 40 ? width : fallbackNotchWidth, height: screen.safeAreaTop)
    }

    /// The header band the tabs sit in: the notch's height, so the controls
    /// flank the camera; a fixed strip where there's no notch.
    static func bandHeight(_ screen: NotchScreen) -> CGFloat {
        screen.hasNotch ? screen.safeAreaTop : flatBandHeight
    }

    /// The gap the camera takes out of the middle of the header band.
    static func cameraGap(_ screen: NotchScreen) -> CGFloat {
        screen.hasNotch ? notchSize(screen).width : 0
    }

    /// Width and height of the collapsed island: the notch itself when
    /// nothing is happening, widened by the glyphs either side otherwise.
    static func collapsedSize(_ screen: NotchScreen, glyphs: NotchGlyphs) -> CGSize {
        let notch = notchSize(screen)
        guard !glyphs.isEmpty else { return notch }
        // Both sides grow together so the island stays centred on the notch.
        let side = max(glyphs.leftWidth, glyphs.rightWidth)
        let height = screen.hasNotch ? notch.height : max(notch.height, flatBandHeight - 6)
        return CGSize(width: notch.width + 2 * side + 2 * collapsedEar, height: height)
    }

    /// The compact one-line peek: the collapsed island with a banner line
    /// hanging under the notch.
    static func peekSize(_ screen: NotchScreen, size: NotchSettings.Size) -> CGSize {
        let width = min(size == .compact ? 400 : 460, max(280, screen.frame.width - 80))
        return CGSize(width: width, height: bandHeight(screen) + 34)
    }

    static func expandedSize(_ screen: NotchScreen, size: NotchSettings.Size, contentHeight: CGFloat) -> CGSize {
        let width = min(size == .compact ? compactWidth : regularWidth, max(320, screen.frame.width - 40))
        let maxHeight = size == .compact ? compactMaxHeight : regularMaxHeight
        let band = bandHeight(screen)
        let content = max(minContentHeight, min(contentHeight, maxHeight - band))
        return CGSize(width: width, height: band + content)
    }

    /// The most the island ever covers.
    static func maxIslandSize(_ screen: NotchScreen, size: NotchSettings.Size) -> CGSize {
        let width = min(size == .compact ? compactWidth : regularWidth, max(320, screen.frame.width - 40))
        return CGSize(width: width, height: size == .compact ? compactMaxHeight : regularMaxHeight)
    }

    /// An island of `size` hung from the top centre of the screen.
    static func islandRect(_ screen: NotchScreen, size: CGSize) -> CGRect {
        CGRect(x: screen.frame.midX - size.width / 2, y: screen.frame.maxY - size.height,
               width: size.width, height: size.height)
    }

    /// The panel that holds the island at its largest, with room for its
    /// shadow; it never moves or resizes while the island animates inside.
    static func panelRect(_ screen: NotchScreen, size: NotchSettings.Size) -> CGRect {
        let island = maxIslandSize(screen, size: size)
        let width = island.width + 2 * shadowInset
        let height = island.height + shadowInset
        return CGRect(x: screen.frame.midX - width / 2, y: screen.frame.maxY - height, width: width, height: height)
    }

    /// Where the pointer wakes the island: the collapsed island with some
    /// slop, never smaller than a pointer can comfortably land on, and
    /// running up to the very top edge.
    static func hotZone(island: CGRect, screen: NotchScreen) -> CGRect {
        var zone = island.insetBy(dx: -8, dy: 0)
        let minWidth: CGFloat = 160
        if zone.width < minWidth { zone = zone.insetBy(dx: (zone.width - minWidth) / 2, dy: 0) }
        let minHeight: CGFloat = 14
        if zone.height < minHeight { zone.size.height = minHeight }
        zone.origin.y = screen.frame.maxY - zone.height
        return zone
    }

    /// Rectangle containment that includes the top and right edges, since
    /// the pointer rests exactly on the top edge of the screen.
    static func contains(_ rect: CGRect, _ point: CGPoint) -> Bool {
        point.x >= rect.minX && point.x <= rect.maxX && point.y >= rect.minY && point.y <= rect.maxY
    }
}

// MARK: - Which screens

enum NotchScreenChooser {
    /// The displays that should carry a notch right now. `primaryID` is the
    /// display with the menu bar; `pointer` is `NSEvent.mouseLocation`.
    static func targets(displays: NotchSettings.Displays, screens: [NotchScreen], primaryID: Int?,
                        pointer: CGPoint, showWithoutNotch: Bool) -> [Int] {
        guard !screens.isEmpty else { return [] }
        let primary = screens.first { $0.id == primaryID } ?? screens[0]
        let chosen: [NotchScreen]
        switch displays {
        case .main:
            chosen = [primary]
        case .pointer:
            chosen = [screens.first { NotchGeometry.contains($0.frame, pointer) } ?? primary]
        case .all:
            chosen = screens
        }
        return chosen.filter { $0.hasNotch || showWithoutNotch }.map(\.id)
    }
}

enum NotchVisibility {
    /// Whether a notch is drawn on a display: hidden in a full-screen
    /// space unless the person asked for it there.
    static func shouldShow(enabled: Bool, fullScreenFront: Bool, showInFullScreen: Bool) -> Bool {
        enabled && (!fullScreenFront || showInFullScreen)
    }

    /// A window that covers its whole display is a full-screen app's (macOS
    /// full screen, or a game). A few points of slack for the rounding of
    /// scaled displays.
    static func coversScreen(window: CGRect, screen: CGRect) -> Bool {
        let slack: CGFloat = 2
        return window.width >= screen.width - slack && window.height >= screen.height - slack
            && abs(window.minX - screen.minX) <= slack && abs(window.minY - screen.minY) <= slack
    }
}

// MARK: - Glyphs

struct NotchUsageWarning: Equatable {
    enum Level: Equatable { case warn, critical }
    var agent: String
    var percent: Int
    var level: Level

    /// From 80% used the collapsed island says so; from 90% it says it loudly.
    static let warnAt = 0.8
    static let criticalAt = 0.9

    /// The tightest allowance across the agents, when it's worth a glyph.
    static func worst(_ readings: [(agent: String, used: Double)]) -> NotchUsageWarning? {
        guard let top = readings.max(by: { $0.used < $1.used }), top.used >= warnAt else { return nil }
        let percent = Int((min(1, max(0, top.used)) * 100).rounded())
        return NotchUsageWarning(agent: top.agent, percent: percent, level: top.used >= criticalAt ? .critical : .warn)
    }
}

/// What the collapsed island summarises.
struct NotchActivity: Equatable {
    var working = 0
    var needsYou = 0
    /// Waits that have come true and check-ins that are due.
    var ready = 0
    var usage: NotchUsageWarning?

    var isQuiet: Bool { working == 0 && needsYou == 0 && ready == 0 && usage == nil }
}

enum NotchGlyph: Equatable, Identifiable {
    case working(Int)
    case needsYou(Int)
    case ready(Int)
    case usage(NotchUsageWarning)

    var id: String {
        switch self {
        case .working: "working"
        case .needsYou: "needsYou"
        case .ready: "ready"
        case .usage: "usage"
        }
    }

    var count: Int {
        switch self {
        case .working(let n), .needsYou(let n), .ready(let n): n
        case .usage: 0
        }
    }

    /// Room it takes: the mark, plus the count when there's more than one.
    var width: CGFloat {
        switch self {
        case .usage(let warning): 14 + 3 + CGFloat(String(warning.percent).count + 1) * 7
        default: count > 1 ? 14 + 3 + CGFloat(String(count).count) * 6.5 : 14
        }
    }

    var label: String {
        switch self {
        case .working(let n): n == 1 ? "1 agent working" : "\(n) agents working"
        case .needsYou(let n): n == 1 ? "1 agent needs you" : "\(n) agents need you"
        case .ready(let n): n == 1 ? "1 wait or check-in ready" : "\(n) waits or check-ins ready"
        case .usage(let w): "\(w.agent) allowance \(w.percent) percent used"
        }
    }
}

struct NotchGlyphs: Equatable {
    /// Left of the notch, outermost first.
    var left: [NotchGlyph] = []
    var right: [NotchGlyph] = []

    static let spacing: CGFloat = 7
    static let padding: CGFloat = 9

    var isEmpty: Bool { left.isEmpty && right.isEmpty }

    var leftWidth: CGFloat { Self.width(left) }
    var rightWidth: CGFloat { Self.width(right) }

    private static func width(_ glyphs: [NotchGlyph]) -> CGFloat {
        guard !glyphs.isEmpty else { return 0 }
        return glyphs.map(\.width).reduce(0, +) + spacing * CGFloat(glyphs.count - 1) + 2 * padding
    }

    /// Agents on the left (what's happening: working, then the amber
    /// "needs you" beside the notch), the things that want a look on the
    /// right (a wait or check-in ready, then an allowance running out).
    static func make(_ activity: NotchActivity) -> NotchGlyphs {
        var glyphs = NotchGlyphs()
        if activity.working > 0 { glyphs.left.append(.working(activity.working)) }
        if activity.needsYou > 0 { glyphs.left.append(.needsYou(activity.needsYou)) }
        if activity.ready > 0 { glyphs.right.append(.ready(activity.ready)) }
        if let usage = activity.usage { glyphs.right.append(.usage(usage)) }
        return glyphs
    }

    var accessibilityLabel: String {
        let all = (left + right).map(\.label)
        return all.isEmpty ? "Octet Notch, nothing happening" : "Octet Notch: " + all.joined(separator: ", ")
    }
}

// MARK: - Agent rows

struct NotchAgentRow: Equatable, Identifiable {
    enum Status: Int, Comparable {
        case needsInput, working, done
        static func < (a: Status, b: Status) -> Bool { a.rawValue < b.rawValue }
    }

    let id: String
    let vendor: String?
    let title: String
    let workspace: String?
    let detail: String?
    let status: Status
    /// When the wait or the work began, or when it finished.
    let since: Date?
    var canStop = false
    /// Waiting in a terminal, where a typed line reaches it.
    var canReply = false
}

enum NotchAgentOrdering {
    /// Waiting on you first (longest-waiting at the top), then what's
    /// working (longest-running first, so rows keep their place as new work
    /// joins below), then what has settled, newest first.
    static func sorted(_ rows: [NotchAgentRow]) -> [NotchAgentRow] {
        rows.sorted { a, b in
            if a.status != b.status { return a.status < b.status }
            switch a.status {
            case .needsInput, .working:
                if a.since != b.since { return (a.since ?? .distantFuture) < (b.since ?? .distantFuture) }
            case .done:
                if a.since != b.since { return (a.since ?? .distantPast) > (b.since ?? .distantPast) }
            }
            if a.title != b.title { return a.title.localizedCaseInsensitiveCompare(b.title) == .orderedAscending }
            return a.id < b.id
        }
    }

    /// The rows that fit, with what was left out: waiting and working rows
    /// always show, settled ones fill what room is left.
    static func visible(_ rows: [NotchAgentRow], limit: Int) -> (shown: [NotchAgentRow], hidden: Int) {
        let ordered = sorted(rows)
        let urgent = ordered.filter { $0.status != .done }
        let settled = ordered.filter { $0.status == .done }
        let room = max(0, limit - urgent.count)
        let shown = urgent + settled.prefix(room)
        return (shown, ordered.count - shown.count)
    }

    static func activity(of rows: [NotchAgentRow]) -> (working: Int, needsYou: Int) {
        (rows.filter { $0.status == .working }.count, rows.filter { $0.status == .needsInput }.count)
    }
}

// MARK: - Peeks

struct NotchPeek: Equatable {
    var kind: AgentEvent.Kind
    var agent: String?
    /// "migrate schema finished", "review auth flow needs you".
    var line: String
    /// Other notices rolled into this one.
    var more: Int
}

enum NotchPeekRules {
    static let duration: TimeInterval = 4

    /// A peek is an interruption, so it's only for a person looking away:
    /// not while Octet is in front, not if turned off, and not on top of a
    /// panel that's already open.
    static func shouldPeek(enabled: Bool, octetActive: Bool, visible: Bool, phase: NotchMachine.Phase) -> Bool {
        enabled && !octetActive && visible && phase != .expanded
    }

    /// One line for a batch of notices: someone waiting on you outranks
    /// someone finishing; the rest are counted.
    static func compose(_ events: [AgentEvent]) -> NotchPeek? {
        guard !events.isEmpty else { return nil }
        let lead = events.last { $0.kind == .needsInput } ?? events.last!
        let who = lead.label.trimmingCharacters(in: .whitespaces).isEmpty
            ? (AgentBrand.forAgent(lead.agent)?.displayName ?? "An agent") : lead.label
        return NotchPeek(kind: lead.kind, agent: lead.agent, line: "\(who) \(lead.kind.title)", more: events.count - 1)
    }
}

// MARK: - Interaction

/// Hover / click / grace-delay behaviour, without a clock: it says what to
/// do and which timer to start, and the controller does it. A stale timer
/// (one that was replaced or cancelled) is ignored when it fires.
struct NotchMachine: Equatable {
    enum Phase: Equatable { case collapsed, peek, expanded }
    enum Timer: Equatable { case expand, collapse, endPeek }
    enum Action: Equatable {
        case expand
        case collapse
        case showPeek
        case startTimer(Timer, TimeInterval)
        case cancelTimer
    }
    enum Event: Equatable {
        case pointerEntered, pointerExited
        case clicked
        case escape
        case clickedAway
        case textFocus(Bool)
        case timerFired(Timer)
        case peek(TimeInterval)
    }

    static let hoverDelay: TimeInterval = 0.15
    static let collapseGrace: TimeInterval = 0.35
    static let peekGrace: TimeInterval = 0.6

    var phase: Phase = .collapsed
    var expandOnHover = true
    private(set) var inside = false
    private(set) var textFocused = false
    private(set) var pending: Timer?

    init(expandOnHover: Bool = true) { self.expandOnHover = expandOnHover }

    mutating func handle(_ event: Event) -> [Action] {
        switch event {
        case .pointerEntered:
            inside = true
            switch phase {
            case .collapsed:
                return expandOnHover ? start(.expand, Self.hoverDelay) : []
            case .peek:
                // Coming to a peek means coming to read it; hover opens the
                // full island, a click-to-open setting waits for the click.
                return expandOnHover ? open() : cancel()
            case .expanded:
                return cancel()
            }
        case .pointerExited:
            inside = false
            switch phase {
            case .collapsed: return cancel()
            case .peek: return start(.endPeek, Self.peekGrace)
            case .expanded: return textFocused ? [] : start(.collapse, Self.collapseGrace)
            }
        case .clicked:
            return phase == .expanded ? [] : open()
        case .escape:
            return phase == .collapsed ? [] : close()
        case .clickedAway:
            return phase == .collapsed || inside ? [] : close()
        case .textFocus(let focused):
            textFocused = focused
            if focused { return phase == .expanded ? cancel() : [] }
            return phase == .expanded && !inside ? start(.collapse, Self.collapseGrace) : []
        case .timerFired(let timer):
            guard pending == timer else { return [] }
            pending = nil
            switch timer {
            case .expand: return phase == .collapsed && inside ? open() : []
            case .collapse: return phase == .expanded && !inside && !textFocused ? close() : []
            case .endPeek: return phase == .peek && !inside ? close() : []
            }
        case .peek(let seconds):
            guard phase != .expanded else { return [] }
            phase = .peek
            pending = .endPeek
            return [.showPeek, .startTimer(.endPeek, seconds)]
        }
    }

    private mutating func open() -> [Action] {
        phase = .expanded
        pending = nil
        return [.cancelTimer, .expand]
    }

    private mutating func close() -> [Action] {
        phase = .collapsed
        pending = nil
        textFocused = false
        return [.cancelTimer, .collapse]
    }

    private mutating func start(_ timer: Timer, _ seconds: TimeInterval) -> [Action] {
        pending = timer
        return [.startTimer(timer, seconds)]
    }

    private mutating func cancel() -> [Action] {
        guard pending != nil else { return [] }
        pending = nil
        return [.cancelTimer]
    }
}

// MARK: - Quick actions

enum NotchAction: String, CaseIterable, Identifiable {
    case newClaude, newCodex, newTab, newWorkspace, palette, openOctet, settings, usage

    var id: String { rawValue }

    var title: String {
        switch self {
        case .newClaude: "New Claude"
        case .newCodex: "New Codex"
        case .newTab: "New Tab"
        case .newWorkspace: "New Workspace"
        case .palette: "Palette"
        case .openOctet: "Open Octet"
        case .settings: "Settings"
        case .usage: "Usage"
        }
    }

    var detail: String {
        switch self {
        case .newClaude: "Start a Claude conversation"
        case .newCodex: "Start a Codex conversation"
        case .newTab: "Open a new terminal tab"
        case .newWorkspace: "Open a new workspace"
        case .palette: "Open the command palette"
        case .openOctet: "Bring Octet forward"
        case .settings: "Open Settings"
        case .usage: "Open the Usage page"
        }
    }

    /// An agent's mark in place of an icon.
    var agent: String? {
        switch self {
        case .newClaude: "claude"
        case .newCodex: "codex"
        default: nil
        }
    }

    var icon: String {
        switch self {
        case .newClaude, .newCodex: "sparkle"
        case .newTab: "terminal"
        case .newWorkspace: "rectangle.stack.badge.plus"
        case .palette: "magnifyingglass"
        case .openOctet: "arrow.up.left.and.arrow.down.right"
        case .settings: "gearshape"
        case .usage: "gauge"
        }
    }
}

// MARK: - Small text helpers

enum NotchText {
    /// "3m", "1h 5m", "2d": the short elapsed time rows end with.
    static func elapsed(from start: Date, now: Date) -> String {
        let seconds = max(0, Int(now.timeIntervalSince(start)))
        if seconds < 60 { return "\(seconds)s" }
        let minutes = seconds / 60
        if minutes < 60 { return "\(minutes)m" }
        let hours = minutes / 60
        if hours < 24 { return minutes % 60 == 0 ? "\(hours)h" : "\(hours)h \(minutes % 60)m" }
        return "\(hours / 24)d"
    }
}
