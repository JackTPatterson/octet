import AppKit
import Combine
import SwiftUI
import os

/// The notch's panel: borderless and non-activating, so a click never takes
/// focus from the app you were in. It only becomes key while a text field in
/// it needs to be typed into.
final class NotchPanel: NSPanel {
    var allowsKey = false
    override var canBecomeKey: Bool { allowsKey }
    override var canBecomeMain: Bool { false }
    /// AppKit keeps windows below the menu bar; the notch lives in it.
    override func constrainFrameRect(_ frameRect: NSRect, to screen: NSScreen?) -> NSRect { frameRect }
}

/// Takes the click that lands on it first, so a button works on the first
/// click even though Octet isn't the active app.
final class NotchHostingView: NSHostingView<NotchRootView> {
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
}

/// One display's island: its panel, its state and its interaction machine.
@MainActor
final class NotchInstance {
    let screenID: Int
    let panel: NotchPanel
    let state: NotchViewState
    var machine: NotchMachine
    var timer: DispatchWorkItem?
    var pointerInside = false
    var hosting: NotchHostingView?
    var geometrySubscription: AnyCancellable?
    var hoverRect = CGRect.zero
    var hitPath: CGPath?
    var cachedIsland = CGRect.zero
    private var cachedEar: CGFloat = -1
    private var cachedBottom: CGFloat = -1
    var peekQueue = NotchPeekQueue()

    func updateGeometry() {
        hoverRect = interactiveRect
        let rect = islandRect
        guard rect != cachedIsland || cachedEar != state.ear || cachedBottom != state.bottomRadius else { return }
        cachedIsland = rect
        cachedEar = state.ear
        cachedBottom = state.bottomRadius
        // SwiftUI paths are y-down; AppKit screen coordinates are y-up.
        var transform = CGAffineTransform(a: 1, b: 0, c: 0, d: -1, tx: rect.minX, ty: rect.maxY)
        hitPath = NotchGeometry.shape(in: CGRect(origin: .zero, size: rect.size), ear: state.ear, bottom: state.bottomRadius)
            .copy(using: &transform)
    }

    func takesClick(at point: CGPoint) -> Bool {
        NotchGeometry.contains(cachedIsland, point) && (hitPath?.contains(point) == true || point.y == cachedIsland.maxY)
    }

    init(screen: NotchScreen, panel: NotchPanel, state: NotchViewState, machine: NotchMachine) {
        screenID = screen.id
        self.panel = panel
        self.state = state
        self.machine = machine
    }

    /// Where the island is on screen right now.
    var islandRect: CGRect { NotchGeometry.islandRect(state.screen, size: state.islandSize) }

    /// Where the pointer counts as being on the notch: the wider hot zone
    /// while it's collapsed, the open island with a little slop otherwise.
    var interactiveRect: CGRect {
        switch state.phase {
        case .collapsed:
            let collapsed = NotchGeometry.islandRect(state.screen, size: NotchGeometry.collapsedSize(state.screen, glyphs: state.glyphs))
            return NotchGeometry.hotZone(island: collapsed, screen: state.screen)
        case .peek, .expanded:
            return islandRect.insetBy(dx: -6, dy: -6)
        }
    }
}

/// The Octet Notch: a black island at the top of the screen that grows out of
/// the MacBook notch (or hangs as a pill where there isn't one) and shows
/// Octet's agents and work from anywhere on the Mac. Off by default.
///
/// Nothing runs while it's off. While it's on and collapsed with nothing
/// happening there are no timers: pointer events (a global mouse monitor)
/// and system notifications are all that wake it.
@MainActor
final class NotchController: NSObject {
    static let shared = NotchController()

    private var instances: [Int: NotchInstance] = [:]
    private let model = NotchModel.shared
    private var observers: [NSObjectProtocol] = []
    private var workspaceObservers: [NSObjectProtocol] = []
    private var monitors: [Any] = []
    private var clickMonitor: Any?
    private var cancellables: Set<AnyCancellable> = []
    private var running = false
    private var lastPointerScreen: Int?
    private var cachedScreens: [NotchScreen] = []
    private var sleeping = false
    /// Verification hook: forces the notch on with sample data, in memory only.
    private var debugSettings: NotchSettings?
    private var isDebug: Bool { debugSettings != nil }

    private var settings: NotchSettings { debugSettings ?? SettingsStore.shared.values.notch }

    // MARK: - Lifecycle

    /// Called at launch and whenever the notch's settings change.
    func apply() {
        if settings.enabled {
            start()
            reconcile()
        } else {
            stop()
        }
    }

    func toggle() {
        SettingsStore.shared.values.notch.enabled.toggle()
    }

    private func start() {
        guard !running else { return }
        running = true
        let center = NotificationCenter.default
        observers.append(center.addObserver(forName: NSApplication.didChangeScreenParametersNotification, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.reconcile() }
        })
        for name in [NSWorkspace.didWakeNotification, NSWorkspace.screensDidWakeNotification] {
            workspaceObservers.append(NSWorkspace.shared.notificationCenter.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.sleeping = false; self?.reconcile() }
            })
        }
        for name in [NSWorkspace.willSleepNotification, NSWorkspace.screensDidSleepNotification] {
            workspaceObservers.append(NSWorkspace.shared.notificationCenter.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.sleeping = true; self?.updateVisibility() }
            })
        }
        // Octet coming forward or stepping back changes whether a peek is
        // welcome, and a click in Octet is a click away from the island.
        let workspace = NSWorkspace.shared.notificationCenter
        workspaceObservers.append(workspace.addObserver(forName: NSWorkspace.activeSpaceDidChangeNotification, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.updateVisibility() }
        })
        workspaceObservers.append(workspace.addObserver(forName: NSWorkspace.didActivateApplicationNotification, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.updateVisibility() }
        })
        model.$snapshot
            .map { $0.activity }
            .removeDuplicates()
            .sink { [weak self] activity in self?.activityChanged(activity) }
            .store(in: &cancellables)
    }

    /// Install only while at least one island is visible. System observers stay
    /// attached so a Space change or wake can bring the island back.
    private func updateMonitoring() {
        let visible = instances.values.contains { $0.panel.isVisible }
        guard visible else {
            monitors.forEach(NSEvent.removeMonitor)
            monitors.removeAll()
            if let clickMonitor { NSEvent.removeMonitor(clickMonitor); self.clickMonitor = nil }
            if !model.isSample { model.stop() }
            return
        }
        if !model.isSample { model.start() }
        updateClickMonitoring()
        guard monitors.isEmpty, !isDebug else { return }
        // Mouse moves anywhere on the Mac; the handler is a few comparisons.
        let moves = NSEvent.addGlobalMonitorForEvents(matching: [.mouseMoved, .leftMouseDragged], handler: { [weak self] _ in
            MainActor.assumeIsolated { self?.pointerMoved() }
        })
        // Events that reach the panel itself (the global monitor doesn't see those).
        let local = NSEvent.addLocalMonitorForEvents(matching: [.mouseMoved, .keyDown, .leftMouseDown, .rightMouseDown, .otherMouseDown], handler: { [weak self] event in
            guard let self else { return event }
            return MainActor.assumeIsolated { self.localEvent(event) }
        })
        monitors = [moves, local].compactMap { $0 }
        updateClickMonitoring()
    }

    private func updateClickMonitoring() {
        let needed = running && !isDebug && instances.values.contains { $0.panel.isVisible && $0.state.phase != .collapsed }
        if needed, clickMonitor == nil {
            clickMonitor = NSEvent.addGlobalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown, .otherMouseDown]) { [weak self] _ in
                MainActor.assumeIsolated { self?.clickedElsewhere() }
            }
        } else if !needed, let clickMonitor {
            NSEvent.removeMonitor(clickMonitor)
            self.clickMonitor = nil
        }
    }

    private func stop() {
        guard running || !instances.isEmpty else { return }
        running = false
        observers.forEach(NotificationCenter.default.removeObserver)
        observers = []
        workspaceObservers.forEach(NSWorkspace.shared.notificationCenter.removeObserver)
        workspaceObservers = []
        monitors.forEach(NSEvent.removeMonitor)
        monitors = []
        if let clickMonitor { NSEvent.removeMonitor(clickMonitor); self.clickMonitor = nil }
        cancellables.removeAll()
        for instance in instances.values { tearDown(instance) }
        instances = [:]
        lastPointerScreen = nil
        if !model.isSample { model.stop() }
    }

    // MARK: - Screens

    private static func screenInfo(_ screen: NSScreen) -> NotchScreen? {
        guard let number = screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber else { return nil }
        return NotchScreen(id: number.intValue, frame: screen.frame, safeAreaTop: screen.safeAreaInsets.top,
                           auxLeftWidth: screen.auxiliaryTopLeftArea?.width ?? 0,
                           auxRightWidth: screen.auxiliaryTopRightArea?.width ?? 0)
    }

    private func reconcile() {
        guard running else { return }
        let screens = NSScreen.screens.compactMap(Self.screenInfo)
        cachedScreens = screens
        let targets = NotchScreenChooser.targets(
            displays: debugSettings != nil ? .main : settings.displays, screens: screens,
            primaryID: NSScreen.screens.first.flatMap(Self.screenInfo)?.id,
            pointer: NSEvent.mouseLocation, showWithoutNotch: settings.showWithoutNotch)
        for (id, instance) in instances where !targets.contains(id) {
            tearDown(instance)
            instances[id] = nil
        }
        for screen in screens where targets.contains(screen.id) {
            let instance = instances[screen.id] ?? makeInstance(screen)
            if instance.state.screen != screen { instance.state.screen = screen }
            if instance.state.settings != settings { instance.state.settings = settings }
            instance.machine.expandOnHover = settings.expand == .hover
            instance.machine.openingDelay = Double(settings.hoverDelayMS) / 1000
            let frame = NotchGeometry.panelRect(screen, size: settings.size)
            if instance.panel.frame != frame { instance.panel.setFrame(frame, display: false) }
            let glyphs = NotchGlyphs.make(model.snapshot.activity)
            if instance.state.glyphs != glyphs { instance.state.glyphs = glyphs }
            instance.updateGeometry()
        }
        updateVisibility()
        pointerMoved()
    }

    private func makeInstance(_ screen: NotchScreen) -> NotchInstance {
        let panel = NotchPanel(contentRect: .zero, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: true)
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = false
        panel.isFloatingPanel = true
        // Above the menu bar, where the notch is (after isFloatingPanel,
        // which resets the level).
        panel.level = NSWindow.Level(rawValue: NotchGeometry.panelLevel)
        panel.hidesOnDeactivate = false
        panel.isReleasedWhenClosed = false
        panel.becomesKeyOnlyIfNeeded = true
        panel.acceptsMouseMovedEvents = true
        panel.ignoresMouseEvents = true
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary, .ignoresCycle]
        // The snapshot helper names secondary windows by title.
        panel.title = "Octet Notch"
        let state = NotchViewState(screen: screen)
        let instance = NotchInstance(screen: screen, panel: panel, state: state,
                                     machine: NotchMachine(expandOnHover: settings.expand == .hover))
        let root = NotchRootView(state: state, model: model, actions: actions(for: instance))
        let hosting = NotchHostingView(rootView: root)
        hosting.sizingOptions = []
        hosting.setAccessibilityLabel("Octet Notch")
        panel.contentView = hosting
        instance.hosting = hosting
        if let tab = UserDefaults.standard.string(forKey: "octet.notch.lastTab").flatMap(NotchTab.init(rawValue:)) { state.tab = tab }
        instance.geometrySubscription = state.objectWillChange
            .receive(on: DispatchQueue.main)
            .sink { [weak instance] in
                guard let instance else { return }
                instance.updateGeometry()
                instance.panel.ignoresMouseEvents = !instance.panel.isVisible || !instance.takesClick(at: NSEvent.mouseLocation)
            }
        instance.updateGeometry()
        instances[screen.id] = instance
        return instance
    }

    private func tearDown(_ instance: NotchInstance) {
        instance.timer?.cancel()
        instance.timer = nil
        instance.geometrySubscription = nil
        instance.panel.orderOut(nil)
        instance.panel.contentView = nil
        instance.hosting = nil
        instance.panel.close()
    }

    // MARK: - Visibility

    /// Hides the notch in a full-screen space unless it was asked for there.
    private func updateVisibility() {
        for instance in instances.values {
            let fullScreen = Self.fullScreenFront(on: instance.screenID)
            let show = NotchVisibility.shouldShow(enabled: settings.enabled && !sleeping, fullScreenFront: fullScreen,
                                                  showInFullScreen: settings.showInFullScreen)
            if show {
                if !instance.panel.isVisible { instance.panel.orderFrontRegardless() }
            } else if instance.panel.isVisible {
                collapse(instance)
                instance.panel.orderOut(nil)
                instance.panel.ignoresMouseEvents = true
                instance.pointerInside = false
                instance.machine = NotchMachine(expandOnHover: settings.expand == .hover)
                instance.machine.openingDelay = Double(settings.hoverDelayMS) / 1000
            }
        }
        updateMonitoring()
        // A Space change may reveal the island under a stationary pointer.
        // Prime hit-testing now so its first click doesn't fall through.
        if !isDebug {
            let point = NSEvent.mouseLocation
            for instance in instances.values { evaluate(instance, at: point) }
        }
    }

    /// Whether some window covers the whole display, as a full-screen app's
    /// does (Octet's own full screen counts: its menu bar is hidden too).
    private static func fullScreenFront(on displayID: Int) -> Bool {
        let bounds = CGDisplayBounds(CGDirectDisplayID(displayID))
        guard let windows = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID) as? [[String: Any]] else { return false }
        return windows.contains { info in
            guard (info[kCGWindowLayer as String] as? Int) == 0,
                  let boundsDict = info[kCGWindowBounds as String] as? NSDictionary,
                  let rect = CGRect(dictionaryRepresentation: boundsDict) else { return false }
            return NotchVisibility.coversScreen(window: rect, screen: bounds)
        }
    }

    // MARK: - Pointer

    private func pointerMoved() {
        guard running, !isDebug else { return }
        let point = NSEvent.mouseLocation
        if settings.displays == .pointer, !isDebug {
            let current = cachedScreens.first { NotchGeometry.contains($0.frame, point) }?.id
            if current != lastPointerScreen {
                lastPointerScreen = current
                // The island moves to the display the pointer went to, unless
                // it's open where it was.
                if instances.values.allSatisfy({ $0.state.phase == .collapsed }) { reconcile() }
            }
        }
        for instance in instances.values { evaluate(instance, at: point) }
    }

    private func evaluate(_ instance: NotchInstance, at point: CGPoint) {
        guard instance.panel.isVisible else { return }
        if !instance.pointerInside && instance.panel.ignoresMouseEvents && point.y < instance.hoverRect.minY { return }
        let inside = NotchGeometry.contains(instance.hoverRect, point)
        if inside != instance.pointerInside {
            instance.pointerInside = inside
            run(instance.machine.handle(inside ? .pointerEntered : .pointerExited), on: instance)
        }
        // The empty parts of the panel never take a click.
        let ignores = !instance.takesClick(at: point)
        if instance.panel.ignoresMouseEvents != ignores { instance.panel.ignoresMouseEvents = ignores }
    }

    private func clickedElsewhere() {
        // The sample shown by the debug hooks stays put for its snapshot.
        guard !isDebug else { return }
        let point = NSEvent.mouseLocation
        for instance in instances.values where instance.state.phase != .collapsed {
            if !NotchGeometry.contains(instance.interactiveRect, point) {
                run(instance.machine.handle(.clickedAway), on: instance)
            }
        }
    }

    private func localEvent(_ event: NSEvent) -> NSEvent? {
        switch event.type {
        case .mouseMoved:
            pointerMoved()
        case .leftMouseDown, .rightMouseDown, .otherMouseDown:
            clickedElsewhere()
        case .keyDown:
            guard let instance = instances.values.first(where: { $0.panel.isKeyWindow && $0.state.phase == .expanded }) else { return event }
            if event.keyCode == 53 {
                run(instance.machine.handle(.escape), on: instance)
                return nil
            }
            // Text editing keeps native arrow/Tab/Return behaviour.
            guard !(instance.panel.firstResponder is NSTextView), event.modifierFlags.intersection([.command, .control, .option]).isEmpty else { return event }
            if event.keyCode == 48 {
                let tabs = settings.shownTabs
                let index = tabs.firstIndex(of: instance.state.tab) ?? 0
                let step = event.modifierFlags.contains(.shift) ? tabs.count - 1 : 1
                actions(for: instance).selectTab(tabs[(index + step) % tabs.count])
                return nil
            }
            if instance.state.tab == .agents {
                let rows = NotchAgentOrdering.visibleOrdered(model.snapshot.agents, limit: settings.size == .compact ? 5 : 7).shown
                guard !rows.isEmpty else { return event }
                if event.keyCode == 125 || event.keyCode == 126 {
                    let current = rows.firstIndex { $0.id == instance.state.selectedAgentID }
                    let next = current.map { min(rows.count - 1, max(0, $0 + (event.keyCode == 125 ? 1 : -1))) } ?? 0
                    instance.state.selectedAgentID = rows[next].id
                    return nil
                }
                if event.keyCode == 36, let row = rows.first(where: { $0.id == instance.state.selectedAgentID }) {
                    actions(for: instance).focus(row)
                    return nil
                }
            }
        default:
            break
        }
        return event
    }

    // MARK: - State machine

    private func run(_ actions: [NotchMachine.Action], on instance: NotchInstance) {
        for action in actions {
            switch action {
            case .expand:
                expand(instance)
            case .collapse:
                collapse(instance)
            case .showPeek:
                MotionPreferences.shared.perform(.palette, Self.spring) { instance.state.phase = .peek }
            case .startTimer(let timer, let seconds):
                instance.timer?.cancel()
                let work = DispatchWorkItem { [weak self, weak instance] in
                    guard let self, let instance else { return }
                    MainActor.assumeIsolated {
                        instance.timer = nil
                        if timer == .endPeek, instance.machine.pending == .endPeek, !instance.machine.inside {
                            instance.peekQueue.advance()
                            if let next = instance.peekQueue.peek {
                                instance.state.peek = next
                                self.run(instance.machine.handle(.peek(NotchPeekRules.duration)), on: instance)
                                return
                            }
                        }
                        self.run(instance.machine.handle(.timerFired(timer)), on: instance)
                    }
                }
                instance.timer = work
                DispatchQueue.main.asyncAfter(deadline: .now() + seconds, execute: work)
            case .cancelTimer:
                instance.timer?.cancel()
                instance.timer = nil
            }
        }
        instance.updateGeometry()
        updateClickMonitoring()
        // The panel only takes clicks where the island is.
        instance.panel.ignoresMouseEvents = !instance.takesClick(at: NSEvent.mouseLocation)
    }

    private static let spring = Animation.spring(response: 0.30, dampingFraction: 0.86)

    private func expand(_ instance: NotchInstance) {
        #if DEBUG
        let started = CFAbsoluteTimeGetCurrent()
        os_signpost(.begin, log: NotchMetrics.log, name: "Expand handler")
        defer {
            NotchMetrics.expanded(in: (CFAbsoluteTimeGetCurrent() - started) * 1000)
            os_signpost(.end, log: NotchMetrics.log, name: "Expand handler")
        }
        #endif
        instance.state.peek = nil
        instance.peekQueue.clear()
        let tabs = settings.shownTabs
        if !tabs.contains(instance.state.tab) { instance.state.tab = tabs[0] }
        MotionPreferences.shared.perform(.palette, Self.spring) { instance.state.phase = .expanded }
        prepareTab(instance.state.tab)
        if settings.haptic {
            NSHapticFeedbackManager.defaultPerformer.perform(.alignment, performanceTime: .now)
        }
    }

    private func collapse(_ instance: NotchInstance) {
        endText(instance)
        instance.timer?.cancel()
        instance.timer = nil
        MotionPreferences.shared.perform(.palette, Self.spring) {
            instance.state.phase = .collapsed
            instance.state.peek = nil
        }
        instance.peekQueue.clear()
        instance.updateGeometry()
        // Reset the machine too, for a collapse that didn't come from it.
        if instance.machine.phase != .collapsed { _ = instance.machine.handle(.escape) }
        instance.panel.ignoresMouseEvents = !instance.takesClick(at: NSEvent.mouseLocation)
    }

    // MARK: - Data

    private func activityChanged(_ activity: NotchActivity) {
        let glyphs = NotchGlyphs.make(activity)
        for instance in instances.values where instance.state.glyphs != glyphs {
            MotionPreferences.shared.perform(.palette, Self.spring) { instance.state.glyphs = glyphs }
        }
    }

    /// An agent finished or needs you (called by the banner centre before it
    /// decides whether to show its own banner).
    func agentEvents(_ events: [AgentEvent]) {
        guard running, !model.isSample else { return }
        for instance in instances.values {
            guard NotchPeekRules.shouldPeek(enabled: settings.peekOnEvents, octetActive: NSApp.isActive,
                                            visible: instance.panel.isVisible, phase: instance.machine.phase) else { continue }
            let empty = instance.peekQueue.events.isEmpty
            instance.peekQueue.append(events)
            instance.state.peek = instance.peekQueue.peek
            if empty, instance.state.peek != nil {
                run(instance.machine.handle(.peek(NotchPeekRules.duration)), on: instance)
            }
        }
    }

    private func prepareTab(_ tab: NotchTab) {
        guard !model.isSample else { return }
        if tab == .actions { model.loadFolders() }
        if tab == .usage { AccountStore.shared.refreshSoon() }
    }

    // MARK: - Text input

    private func beginText(_ instance: NotchInstance) {
        instance.panel.allowsKey = true
        instance.panel.makeKey()
        run(instance.machine.handle(.textFocus(true)), on: instance)
    }

    private func endText(_ instance: NotchInstance) {
        guard instance.panel.allowsKey else { return }
        instance.panel.allowsKey = false
        if instance.panel.isKeyWindow { instance.panel.resignKey() }
        run(instance.machine.handle(.textFocus(false)), on: instance)
    }

    // MARK: - Actions

    private func actions(for instance: NotchInstance) -> NotchActions {
        var actions = NotchActions()
        actions.keyboardFocus = { [weak instance] in
            guard let instance, instance.state.phase == .expanded else { return }
            instance.panel.allowsKey = true
            instance.panel.makeKey()
        }
        actions.pinTab = { [weak self] tab in
            guard let self, !self.isDebug else { return }
            SettingsStore.shared.values.notch.tabs = [tab] + self.settings.shownTabs.filter { $0 != tab }
        }
        actions.selectTab = { [weak self, weak instance] tab in
            guard let self, let instance else { return }
            self.endText(instance)
            instance.state.tab = tab
            self.prepareTab(tab)
            if !self.isDebug { UserDefaults.standard.set(tab.rawValue, forKey: "octet.notch.lastTab") }
        }
        actions.drop = { [weak self, weak instance] drop in
            guard let self, let instance, !self.model.isSample else { return }
            self.openOctet()
            guard let window = WindowRegistry.shared.key else { return }
            switch drop {
            case .folder(let url): window.openProject(path: url.path)
            case .prompt(let text):
                window.newConversation()
                AgentCenter.shared.active(in: window.focusedWorkspace?.workspaceId)?.prefillComposer(text)
            }
            self.dismiss(instance)
        }

        actions.open = { [weak self, weak instance] in
            guard let self, let instance else { return }
            self.run(instance.machine.handle(.clicked), on: instance)
        }
        actions.dismiss = { [weak self, weak instance] in
            guard let self, let instance else { return }
            self.run(instance.machine.handle(.escape), on: instance)
        }
        actions.beginText = { [weak self, weak instance] in
            guard let self, let instance else { return }
            self.beginText(instance)
        }
        actions.endText = { [weak self, weak instance] in
            guard let self, let instance else { return }
            self.endText(instance)
        }
        // Everything below acts on real windows and sessions; the sample
        // shown by the debug hooks does none of it.
        actions.peekTapped = { [weak self, weak instance] in
            guard let self, let instance, !self.model.isSample else { return }
            if let event = instance.peekQueue.events.first, let window = WindowRegistry.shared.key {
                window.bringForward()
                window.focus(event)
            }
            self.dismiss(instance)
        }
        actions.focus = { [weak self, weak instance] row in
            guard let self, let instance, !self.model.isSample else { return }
            self.focus(row)
            self.dismiss(instance)
        }
        actions.copyMessage = { [weak self] row in
            guard let self, !self.model.isSample else { return }
            var text = row.detail
            if let agent = self.model.hubAgent(row.id), case .chat(let session) = agent.target {
                text = session.conversation.items.reversed().compactMap { item -> String? in
                    if case .text(let text) = item.kind, !text.isEmpty { return text }
                    return nil
                }.first
            }
            if let text {
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(text, forType: .string)
            }
        }
        actions.stop = { [weak self] row in
            guard let self, !self.model.isSample else { return }
            self.model.hubAgent(row.id)?.stop()
        }
        actions.reply = { [weak self] row, text in
            guard let self, !self.model.isSample else { return }
            self.reply(to: row, text: text)
        }
        actions.run = { [weak self, weak instance] action in
            guard let self, let instance, !self.model.isSample else { return }
            self.perform(action)
            self.dismiss(instance)
        }
        actions.openFolder = { [weak self, weak instance] folder in
            guard let self, let instance, !self.model.isSample else { return }
            self.openOctet()
            WindowRegistry.shared.key?.openProject(path: folder.path)
            self.dismiss(instance)
        }
        actions.continueWait = { [weak self, weak instance] wait in
            guard let self, let instance, !self.model.isSample else { return }
            WaitCenter.shared.continueWait(wait.id)
            self.dismiss(instance)
        }
        actions.runCheckIn = { [weak self] checkIn in
            guard let self, !self.model.isSample else { return }
            CheckInCenter.shared.runNow(checkIn.id)
        }
        actions.skipCheckIn = { [weak self] checkIn in
            guard let self, !self.model.isSample else { return }
            CheckInCenter.shared.skipNext(checkIn.id)
        }
        actions.showAgents = { [weak self, weak instance] in
            guard let self, let instance, !self.model.isSample else { return }
            self.openOctet()
            AgentCenter.shared.setBoard(.all, in: WindowRegistry.shared.key?.focusedWorkspace?.workspaceId)
            self.dismiss(instance)
        }
        actions.settings = { [weak self, weak instance] in
            guard let self, let instance, !self.model.isSample else { return }
            SettingsOpener.open(.notch)
            self.dismiss(instance)
        }
        return actions
    }

    private func dismiss(_ instance: NotchInstance) {
        run(instance.machine.handle(.escape), on: instance)
    }

    private func openOctet() {
        if let window = WindowRegistry.shared.key ?? WindowRegistry.shared.windows.first {
            window.bringForward()
        } else {
            NSApp.activate(ignoringOtherApps: true)
        }
    }

    /// Goes to the agent where it runs, in whichever window has it.
    private func focus(_ row: NotchAgentRow) {
        openOctet()
        guard let window = WindowRegistry.shared.key, let agent = model.hubAgent(row.id) else { return }
        switch agent.target {
        case .chat(let session):
            window.focusWorkspace(session.workspaceId)
            AgentCenter.shared.setActive(session.id, in: session.workspaceId)
        case .terminal(let tab):
            AgentCenter.shared.setActive(nil, in: tab.workspaceId)
            window.focusTabAnywhere(tab)
            OctetTerminalRuntime.focusTerminal()
        case .claudeBackground, .codexBackground:
            AgentCenter.shared.setBoard(.all, in: window.focusedWorkspace?.workspaceId)
        }
    }

    /// A typed reply for an agent waiting in a terminal, sent the way a
    /// check-in sends its prompt: the line, then Return.
    private func reply(to row: NotchAgentRow, text: String) {
        guard let agent = model.hubAgent(row.id), case .terminal = agent.target,
              row.id.hasPrefix("pane:"), let store = model.store(for: row.id) else { return }
        let paneId = String(row.id.dropFirst("pane:".count))
        let line = text.split(whereSeparator: \.isNewline).joined(separator: " ")
        let client = store.client
        DispatchQueue.global(qos: .userInitiated).async {
            _ = try? client.call("pane.send_text", ["pane_id": paneId, "text": line])
            Thread.sleep(forTimeInterval: 0.15)
            _ = try? client.call("pane.send_text", ["pane_id": paneId, "text": "\r"])
        }
    }

    private func perform(_ action: NotchAction) {
        if action == .settings {
            SettingsOpener.open()
            return
        }
        openOctet()
        guard let window = WindowRegistry.shared.key else { return }
        switch action {
        case .newClaude: window.newConversation(engine: .claude)
        case .newCodex: window.newConversation(engine: .codex)
        case .newTab: window.newTab()
        case .newWorkspace: window.newWorkspace()
        case .palette: window.ui.paletteVisible = true
        case .usage: window.ui.usageBreakdownVisible = true
        case .openOctet, .settings: break
        }
    }

    // MARK: - Verification

    #if DEBUG
    func debugPerformanceDump() {
        NotchMetrics.dump(monitors: monitors.count + (clickMonitor == nil ? 0 : 1),
                          timers: instances.values.filter { $0.timer != nil }.count + model.debugPendingWork,
                          subscriptions: model.debugSubscriptions, sample: model.isSample)
    }

    /// The debug hooks' way in: the notch on, in memory only, over sample
    /// data that nothing live is read from or sent to.
    func debugShow(phase: NotchMachine.Phase, tab: NotchTab?, size: NotchSettings.Size = .regular) {
        var forced = NotchSettings()
        forced.enabled = true
        forced.size = size
        forced.haptic = false
        stop()
        debugSettings = forced
        model.installSample(NotchSample.snapshot)
        running = false
        start()
        reconcile()
        for instance in instances.values {
            if let tab { instance.state.tab = tab }
            switch phase {
            case .collapsed:
                break
            case .expanded:
                run(instance.machine.handle(.clicked), on: instance)
            case .peek:
                instance.state.peek = NotchSample.peek
                // Long enough to be captured.
                run(instance.machine.handle(.peek(600)), on: instance)
            }
        }
        // A text record of what the island believes, beside the snapshots.
        guard let dir = ProcessInfo.processInfo.environment["OCTET_SNAPSHOT_DIR"] else { return }
        for delay in [1.0, 4.0] {
            DispatchQueue.main.asyncAfter(deadline: .now() + delay) { [weak self] in
                guard let self else { return }
                let text = self.instances.values.map { instance in
                    "screen=\(instance.screenID) hasNotch=\(instance.state.screen.hasNotch) safeTop=\(instance.state.screen.safeAreaTop) "
                        + "phase=\(instance.state.phase) machine=\(instance.machine.phase) island=\(instance.state.islandSize) "
                        + "panel=\(NSStringFromRect(instance.panel.frame)) visible=\(instance.panel.isVisible) "
                        + "ignoresMouse=\(instance.panel.ignoresMouseEvents) level=\(instance.panel.level.rawValue) "
                        + "glyphs=\(instance.state.glyphs.accessibilityLabel) contentHeight=\(instance.state.contentHeight)"
                }.joined(separator: "\n")
                self.debugPerformanceDump()
                try? text.write(toFile: dir + "/notch-state.txt", atomically: true, encoding: .utf8)
            }
        }
    }
    #endif
}
