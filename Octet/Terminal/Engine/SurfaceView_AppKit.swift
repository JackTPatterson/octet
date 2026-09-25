// The terminal surface view. No splits/tabs/inspector/search/secure input/notifications/
// restoration/key tables/progress reports/derived config. The view is used
// directly as an AppKit view (no SurfaceScrollView wrapper), so frame changes
// drive `sizeDidChange` and window key notifications drive focus.

import AppKit
import Combine
import CoreText
import GhosttyKit
import System

extension TerminalEngine {
    /// The NSView implementation for a terminal surface.
    class SurfaceView: NSView, ObservableObject, Identifiable {
        typealias ID = UUID

        /// Unique ID per surface
        let id: UUID

        // The current title of the surface as defined by the pty. This can be
        // changed with escape codes.
        @Published private(set) var title: String = "" {
            didSet {
                if title != oldValue { onTitleChange?(title) }
            }
        }

        // The current pwd of the surface as defined by the pty.
        @Published var pwd: String?

        // The cell size of this surface. This is set by the core when the
        // surface is first created and any time the cell size changes.
        @Published var cellSize: CGSize = .zero

        // The health state of the surface (renderer health).
        @Published var healthy: Bool = true

        // Any error while initializing the surface.
        @Published var error: Swift.Error?

        // The hovered URL string
        @Published var hoverUrl: String?

        // Returns sizing information for the surface.
        @Published var surfaceSize: ghostty_surface_size_s?

        // Whether the pointer should be visible or not
        @Published private(set) var pointerStyle: CursorStyle = .horizontalText

        // Whether the mouse is currently over this surface
        @Published private(set) var mouseOverSurface: Bool = false

        // Whether the cursor is currently visible (not hidden by typing, etc.)
        @Published private(set) var cursorVisible: Bool = true

        // MARK: Octet hooks

        /// Called on the main thread whenever the terminal title changes.
        var onTitleChange: ((String) -> Void)?

        /// Called once on the main thread when the child process exits or the
        /// core requests the surface/window be closed.
        var onExit: (() -> Void)?
        private var didExit = false

        /// When true, the view makes itself first responder the next time it is
        /// attached to a window.
        var focusOnAttach: Bool = false

        func notifyExit() {
            guard !didExit else { return }
            didExit = true
            onExit?()
        }

        // A content size received through sizeDidChange that may in some cases
        // be different from the frame size.
        private var contentSizeBacking: NSSize?
        private var contentSize: NSSize {
            get { return contentSizeBacking ?? frame.size }
            set { contentSizeBacking = newValue }
        }

        // Returns true if the process in this surface has exited.
        var processExited: Bool {
            guard let surface = self.surface else { return true }
            return ghostty_surface_process_exited(surface)
        }

        /// Returns the data model for this surface.
        private(set) var surfaceModel: TerminalEngine.Surface?

        /// Returns the underlying C value for the surface.
        var surface: ghostty_surface_t? {
            surfaceModel?.unsafeCValue
        }

        private var markedText: NSMutableAttributedString
        private(set) var focused: Bool = true
        private var prevPressureStage: Int = 0

        // This is set to non-null during keyDown to accumulate insertText contents
        private var keyTextAccumulator: [String]?

        // True when we've consumed a left mouse-down only to move focus and
        // should suppress the matching mouse-up from being reported.
        private var suppressNextLeftMouseUp: Bool = false

        // A small delay that is introduced before a title change to avoid flickers
        private var titleChangeTimer: Timer?

        /// Event monitor (see individual events for why)
        private var eventMonitor: Any?

        /// What VoiceOver reads: the visible terminal text, cached briefly
        /// because assistive tools ask for it many times in a row.
        private(set) lazy var cachedScreenContents = CachedValue<String>(duration: .milliseconds(500)) { [weak self] in
            self?.readVisibleText() ?? ""
        }

        // We need to support being a first responder so that we can get input events
        override var acceptsFirstResponder: Bool { return true }

        init(_ app: ghostty_app_t, baseConfig: SurfaceConfiguration? = nil, uuid: UUID? = nil) {
            self.markedText = NSMutableAttributedString()
            self.id = uuid ?? UUID()

            // Initialize with some default frame size. The important thing is that this
            // is non-zero so that our layer bounds are non-zero so that our renderer
            // can do SOMETHING.
            super.init(frame: NSRect(x: 0, y: 0, width: 800, height: 600))

            // Before we initialize the surface we want to register our notifications
            // so there is no window where we can't receive them.
            let center = NotificationCenter.default
            center.addObserver(
                self,
                selector: #selector(windowDidChangeScreen),
                name: NSWindow.didChangeScreenNotification,
                object: nil)
            center.addObserver(
                self,
                selector: #selector(windowKeyStateDidChange),
                name: NSWindow.didBecomeKeyNotification,
                object: nil)
            center.addObserver(
                self,
                selector: #selector(windowKeyStateDidChange),
                name: NSWindow.didResignKeyNotification,
                object: nil)

            // Listen for local events that we need to know of outside of
            // single surface handlers.
            self.eventMonitor = NSEvent.addLocalMonitorForEvents(
                matching: [
                    // We need keyUp because command+key events don't trigger keyUp.
                    .keyUp,

                    // We need leftMouseDown to determine if we should focus ourselves
                    // when the app/window isn't in focus. We do this instead of
                    // "acceptsFirstMouse" because that forces us to also handle the
                    // event and encode the event to the pty which we want to avoid.
                    // (Issue 2595)
                    .leftMouseDown,
                ]
            ) { [weak self] event in self?.localEventHandler(event) }

            // Setup our surface. This will also initialize all the terminal IO.
            let surface_cfg = baseConfig ?? SurfaceConfiguration()
            let surface = surface_cfg.withCValue(view: self) { surface_cfg_c in
                ghostty_surface_new(app, &surface_cfg_c)
            }
            guard let surface = surface else {
                TerminalEngine.logger.critical("ghostty_surface_new failed")
                return
            }
            self.surfaceModel = TerminalEngine.Surface(cSurface: surface)

            // Setup our tracking area so we get mouse moved events
            updateTrackingAreas()

            // The UTTypes that can be dragged onto this view.
            registerForDraggedTypes(Array(Self.dropTypes))
        }

        required init?(coder: NSCoder) {
            fatalError("init(coder:) is not supported for this view")
        }

        deinit {
            // Remove all of our notificationcenter subscriptions
            NotificationCenter.default.removeObserver(self)

            // Remove our event monitor
            if let eventMonitor {
                NSEvent.removeMonitor(eventMonitor)
            }

            trackingAreas.forEach { removeTrackingArea($0) }
            titleChangeTimer?.invalidate()
        }

        func focusDidChange(_ focused: Bool) {
            guard let surface = self.surface else { return }
            guard self.focused != focused else { return }
            self.focused = focused

            // If we lost our focus then remove the mouse event suppression so
            // our mouse release event leaving the surface can properly be
            // sent to stop things like mouse selection.
            if !focused {
                suppressNextLeftMouseUp = false
            }

            // Notify the engine
            ghostty_surface_set_focus(surface, focused)
        }

        func sizeDidChange(_ size: CGSize) {
            // The engine wants to know the actual framebuffer size... It is very important
            // here that we use "size" and NOT the view frame. If we're in the middle of
            // an animation (i.e. a fullscreen animation), the frame will not yet be updated.
            // The size represents our final size we're going for.
            let scaledSize = self.convertToBacking(size)
            setSurfaceSize(width: UInt32(scaledSize.width), height: UInt32(scaledSize.height))
            // Store this size so we can reuse it when backing properties change
            contentSize = size
        }

        private func setSurfaceSize(width: UInt32, height: UInt32) {
            guard let surface = self.surface else { return }
            guard width > 0, height > 0 else { return }

            // Update our core surface
            ghostty_surface_set_size(surface, width, height)

            // Update our cached size metrics
            let size = ghostty_surface_size(surface)
            DispatchQueue.main.async {
                // DispatchQueue required since this may be called by SwiftUI off
                // the main thread and Published changes need to be on the main
                // thread. This caused a crash on macOS <= 14.
                self.surfaceSize = size
            }
        }

        func setCursorShape(_ shape: ghostty_action_mouse_shape_e) {
            switch shape {
            case GHOSTTY_MOUSE_SHAPE_DEFAULT:
                pointerStyle = .default

            case GHOSTTY_MOUSE_SHAPE_TEXT:
                pointerStyle = .horizontalText

            case GHOSTTY_MOUSE_SHAPE_GRAB:
                pointerStyle = .grabIdle

            case GHOSTTY_MOUSE_SHAPE_GRABBING:
                pointerStyle = .grabActive

            case GHOSTTY_MOUSE_SHAPE_POINTER:
                pointerStyle = .link

            case GHOSTTY_MOUSE_SHAPE_W_RESIZE:
                pointerStyle = .resizeLeft

            case GHOSTTY_MOUSE_SHAPE_E_RESIZE:
                pointerStyle = .resizeRight

            case GHOSTTY_MOUSE_SHAPE_N_RESIZE:
                pointerStyle = .resizeUp

            case GHOSTTY_MOUSE_SHAPE_S_RESIZE:
                pointerStyle = .resizeDown

            case GHOSTTY_MOUSE_SHAPE_NS_RESIZE:
                pointerStyle = .resizeUpDown

            case GHOSTTY_MOUSE_SHAPE_EW_RESIZE:
                pointerStyle = .resizeLeftRight

            case GHOSTTY_MOUSE_SHAPE_VERTICAL_TEXT:
                pointerStyle = .verticalText

            case GHOSTTY_MOUSE_SHAPE_CONTEXT_MENU:
                pointerStyle = .contextMenu

            case GHOSTTY_MOUSE_SHAPE_CROSSHAIR:
                pointerStyle = .crosshair

            case GHOSTTY_MOUSE_SHAPE_NOT_ALLOWED:
                pointerStyle = .operationNotAllowed

            default:
                // We ignore unknown shapes.
                return
            }

            // A SwiftUI host would apply pointerStyle via a modifier. We are a
            // plain NSView, so apply it through cursor rects instead.
            window?.invalidateCursorRects(for: self)
            if mouseOverSurface {
                pointerStyle.cursor.set()
            }
        }

        override func resetCursorRects() {
            addCursorRect(bounds, cursor: pointerStyle.cursor)
        }

        func setCursorVisibility(_ visible: Bool) {
            cursorVisible = visible
            // Technically this action could be called anytime we want to
            // change the mouse visibility but at the time of writing this
            // mouse-hide-while-typing is the only use case so this is the
            // preferred method.
            NSCursor.setHiddenUntilMouseMoves(!visible)
        }

        func setTitle(_ title: String) {
            // This fixes an issue where very quick changes to the title could
            // cause an unpleasant flickering. We set a timer so that we can
            // coalesce rapid changes. The timer is short enough that it still
            // feels "instant".
            titleChangeTimer?.invalidate()
            titleChangeTimer = Timer.scheduledTimer(
                withTimeInterval: 0.075,
                repeats: false
            ) { [weak self] _ in
                self?.title = title
            }
        }

        // MARK: Local Events

        private func localEventHandler(_ event: NSEvent) -> NSEvent? {
            return switch event.type {
            case .keyUp:
                localEventKeyUp(event)

            case .leftMouseDown:
                localEventLeftMouseDown(event)

            default:
                event
            }
        }

        private func localEventLeftMouseDown(_ event: NSEvent) -> NSEvent? {
            // We only want to process events that are on this window.
            guard let window,
                  event.window != nil,
                  window == event.window else { return event }

            // The clicked location in this window should be this view.
            guard
                let location = window.contentView?.convert(event.locationInWindow, from: nil)
            else {
                return event
            }
            // We should use window to perform hitTest here,
            // because there could be some other overlays on top, like search bar
            guard window.contentView?.hitTest(location) == self else { return event }

            // We always assume that we're resetting our mouse suppression
            // unless we see the specific scenario below to set it.
            suppressNextLeftMouseUp = false

            // If we're already the first responder then no focus transfer is
            // happening, so the click should continue as normal.
            guard window.firstResponder !== self else {
                return event
            }

            // If our window/app is already focused, then this click is only
            // being used to transfer focus. Consume it so it does not
            // get forwarded to the terminal as a mouse click.
            if NSApp.isActive && window.isKeyWindow {
                window.makeFirstResponder(self)
                suppressNextLeftMouseUp = true
                return nil
            }

            // Make ourselves the first responder
            window.makeFirstResponder(self)

            // We have to keep processing the event so that AppKit can properly
            // focus the window and dispatch events. If you return nil here then
            // nobody gets a windowDidBecomeKey event and so on.
            return event
        }

        private func localEventKeyUp(_ event: NSEvent) -> NSEvent? {
            // We only care about events with "command" because all others will
            // trigger the normal responder chain.
            if !event.modifierFlags.contains(.command) { return event }

            // Command keyUp events are never sent to the normal responder chain
            // so we send them here.
            guard focused else { return event }
            self.keyUp(with: event)
            return nil
        }

        // MARK: - Notifications

        @objc private func windowDidChangeScreen(notification: Foundation.Notification) {
            guard let window = self.window else { return }
            guard let object = notification.object as? NSWindow, window == object else { return }
            guard let screen = window.screen else { return }
            guard let surface = self.surface else { return }

            // When the window changes screens, we need to update the engine with the screen
            // ID. If vsync is enabled, this will be used with the CVDisplayLink to ensure
            // the proper refresh rate is going.
            ghostty_surface_set_display_id(surface, screen.displayID ?? 0)

            // We also just trigger a backing property change. Just in case the screen has
            // a different scaling factor, this ensures that we update our content scale.

            DispatchQueue.main.async { [weak self] in
                self?.viewDidChangeBackingProperties()
            }
        }

        /// Octet: replaces BaseTerminalController.syncFocusToSurfaceTree. Our focus
        /// state requires that the window is key and we are its first responder.
        @objc private func windowKeyStateDidChange(notification: Foundation.Notification) {
            guard let window = self.window else { return }
            guard let object = notification.object as? NSWindow, window == object else { return }
            DispatchQueue.main.async { [weak self] in
                self?.syncFocus()
            }
        }

        private func syncFocus() {
            guard let window else { return }
            focusDidChange(window.isKeyWindow && window.firstResponder === self)
        }

        // MARK: - NSView

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            guard let window, let surface else { return }
            if let screen = window.screen {
                ghostty_surface_set_display_id(surface, screen.displayID ?? 0)
            }
            viewDidChangeBackingProperties()
            sizeDidChange(frame.size)
            syncFocus()

            if focusOnAttach {
                focusOnAttach = false
                DispatchQueue.main.async { [weak self] in
                    guard let self, let window = self.window else { return }
                    window.makeFirstResponder(self)
                }
            }
        }

        override func setFrameSize(_ newSize: NSSize) {
            super.setFrameSize(newSize)
            sizeDidChange(newSize)
        }

        override func becomeFirstResponder() -> Bool {
            let result = super.becomeFirstResponder()
            if result { focusDidChange(window?.isKeyWindow ?? true) }
            return result
        }

        override func resignFirstResponder() -> Bool {
            let result = super.resignFirstResponder()
            if result { focusDidChange(false) }
            return result
        }

        override func updateTrackingAreas() {
            // To update our tracking area we just recreate it all.
            trackingAreas.forEach { removeTrackingArea($0) }

            // This tracking area is across the entire frame to notify us of mouse movements.
            addTrackingArea(NSTrackingArea(
                rect: frame,
                options: [
                    .mouseEnteredAndExited,
                    .mouseMoved,

                    // Only send mouse events that happen in our visible (not obscured) rect
                    .inVisibleRect,

                    // We want active always because we want to still send mouse reports
                    // even if we're not focused or key.
                    .activeAlways,
                ],
                owner: self,
                userInfo: nil))
        }

        override func viewDidChangeBackingProperties() {
            super.viewDidChangeBackingProperties()

            // The Core Animation compositing engine uses the layer's contentsScale property
            // to determine whether to scale its contents during compositing. When the window
            // moves between a high DPI display and a low DPI display, or the user modifies
            // the DPI scaling for a display in the system settings, this can result in the
            // layer being scaled inappropriately. Since we handle the adjustment of scale
            // and resolution ourselves below, we update the layer's contentsScale property
            // to match the window's backingScaleFactor, so as to ensure it is not scaled by
            // the compositor.
            if let window = window {
                CATransaction.begin()
                // Disable the implicit transition animation that Core Animation applies to
                // property changes. Otherwise it will apply a scale animation to the layer
                // contents which looks pretty janky.
                CATransaction.setDisableActions(true)
                layer?.contentsScale = window.backingScaleFactor
                CATransaction.commit()
            }

            guard let surface = self.surface else { return }
            guard frame.size.width > 0, frame.size.height > 0 else { return }

            // Detect our X/Y scale factor so we can update our surface
            let fbFrame = self.convertToBacking(self.frame)
            let xScale = fbFrame.size.width / self.frame.size.width
            let yScale = fbFrame.size.height / self.frame.size.height
            ghostty_surface_set_content_scale(surface, xScale, yScale)

            // When our scale factor changes, so does our fb size so we send that too
            let scaledSize = self.convertToBacking(contentSize)
            setSurfaceSize(width: UInt32(scaledSize.width), height: UInt32(scaledSize.height))
        }

        override func mouseDown(with event: NSEvent) {
            guard let surface = self.surface else { return }
            let mods = TerminalEngine.engineMods(event.modifierFlags)
            ghostty_surface_mouse_button(surface, GHOSTTY_MOUSE_PRESS, GHOSTTY_MOUSE_LEFT, mods)
        }

        override func mouseUp(with event: NSEvent) {
            // If this mouse-up corresponds to a focus-only click transfer,
            // suppress it so we don't emit a release without a press.
            if suppressNextLeftMouseUp {
                suppressNextLeftMouseUp = false
                return
            }

            // Always reset our pressure when the mouse goes up
            prevPressureStage = 0

            // If we have an active surface, report the event
            guard let surface = self.surface else { return }
            let mods = TerminalEngine.engineMods(event.modifierFlags)
            ghostty_surface_mouse_button(surface, GHOSTTY_MOUSE_RELEASE, GHOSTTY_MOUSE_LEFT, mods)

            // Release pressure
            ghostty_surface_mouse_pressure(surface, 0, 0)
        }

        override func otherMouseDown(with event: NSEvent) {
            guard let surface = self.surface else { return }
            let mods = TerminalEngine.engineMods(event.modifierFlags)
            let button = TerminalEngine.Input.MouseButton(fromNSEventButtonNumber: event.buttonNumber)
            ghostty_surface_mouse_button(surface, GHOSTTY_MOUSE_PRESS, button.cMouseButton, mods)
        }

        override func otherMouseUp(with event: NSEvent) {
            guard let surface = self.surface else { return }
            let mods = TerminalEngine.engineMods(event.modifierFlags)
            let button = TerminalEngine.Input.MouseButton(fromNSEventButtonNumber: event.buttonNumber)
            ghostty_surface_mouse_button(surface, GHOSTTY_MOUSE_RELEASE, button.cMouseButton, mods)
        }

        override func rightMouseDown(with event: NSEvent) {
            // Octet: right-click opens Octet's menu; ⇧ right-click goes to
            // the program in the pane, for the few that use it.
            if !event.modifierFlags.contains(.shift) {
                if let menu = OctetTerminalMenu.menu(for: self) { NSMenu.popUpContextMenu(menu, with: event, for: self) }
                return
            }
            guard let surface = self.surface else { return super.rightMouseDown(with: event) }

            let mods = TerminalEngine.engineMods(event.modifierFlags)
            if ghostty_surface_mouse_button(
                surface,
                GHOSTTY_MOUSE_PRESS,
                GHOSTTY_MOUSE_RIGHT,
                mods
            ) {
                // Consumed
                return
            }

            // Mouse event not consumed
            super.rightMouseDown(with: event)
        }

        override func rightMouseUp(with event: NSEvent) {
            if !event.modifierFlags.contains(.shift) { return }
            guard let surface = self.surface else { return super.rightMouseUp(with: event) }

            let mods = TerminalEngine.engineMods(event.modifierFlags)
            if ghostty_surface_mouse_button(
                surface,
                GHOSTTY_MOUSE_RELEASE,
                GHOSTTY_MOUSE_RIGHT,
                mods
            ) {
                // Handled
                return
            }

            // Mouse event not consumed
            super.rightMouseUp(with: event)
        }

        override func mouseEntered(with event: NSEvent) {
            mouseOverSurface = true
            super.mouseEntered(with: event)

            guard let surfaceModel else { return }

            // On mouse enter we need to reset our cursor position. This is
            // super important because we set it to -1/-1 on mouseExit and
            // lots of mouse logic (i.e. whether to send mouse reports) depend
            // on the position being in the viewport if it is.
            let pos = self.convert(event.locationInWindow, from: nil)
            let mouseEvent = TerminalEngine.Input.MousePosEvent(
                x: pos.x,
                y: frame.height - pos.y,
                mods: .init(nsFlags: event.modifierFlags)
            )
            surfaceModel.sendMousePos(mouseEvent)
        }

        override func mouseExited(with event: NSEvent) {
            mouseOverSurface = false
            guard let surfaceModel else { return }

            // If the mouse is being dragged then we don't have to emit
            // this because we get mouse drag events even if we've already
            // exited the viewport (i.e. mouseDragged)
            if NSEvent.pressedMouseButtons != 0 {
                return
            }

            // Negative values indicate cursor has left the viewport
            let mouseEvent = TerminalEngine.Input.MousePosEvent(
                x: -1,
                y: -1,
                mods: .init(nsFlags: event.modifierFlags)
            )
            surfaceModel.sendMousePos(mouseEvent)
        }

        override func mouseMoved(with event: NSEvent) {
            guard let surfaceModel else { return }

            // Convert window position to view position. Note (0, 0) is bottom left.
            let pos = self.convert(event.locationInWindow, from: nil)
            let mouseEvent = TerminalEngine.Input.MousePosEvent(
                x: pos.x,
                y: frame.height - pos.y,
                mods: .init(nsFlags: event.modifierFlags)
            )
            surfaceModel.sendMousePos(mouseEvent)
        }

        override func mouseDragged(with event: NSEvent) {
            self.mouseMoved(with: event)
        }

        override func rightMouseDragged(with event: NSEvent) {
            self.mouseMoved(with: event)
        }

        override func otherMouseDragged(with event: NSEvent) {
            self.mouseMoved(with: event)
        }

        override func scrollWheel(with event: NSEvent) {
            guard let surfaceModel else { return }

            // Bottom anchoring reads the visible grid. Suppress that polling
            // during a live wheel/trackpad gesture so scrolling never competes
            // with a synchronous terminal text scan on the main thread.
            (superview?.superview as? TopRowClippingView)?.terminalDidScroll()

            var x = event.scrollingDeltaX
            var y = event.scrollingDeltaY
            let precision = event.hasPreciseScrollingDeltas

            if precision {
                // We do a 2x speed multiplier. This is subjective, it "feels" better to me.
                x *= 2
                y *= 2
            }

            let scrollEvent = TerminalEngine.Input.MouseScrollEvent(
                x: x,
                y: y,
                mods: .init(precision: precision, momentum: .init(event.momentumPhase))
            )
            surfaceModel.sendMouseScroll(scrollEvent)
        }

        override func pressureChange(with event: NSEvent) {
            guard let surface = self.surface else { return }

            // Notify the engine first. We do this because this will let the engine handle
            // state setup that we'll need for later pressure handling (such as
            // QuickLook)
            ghostty_surface_mouse_pressure(surface, UInt32(event.stage), Double(event.pressure))

            // Pressure stage 2 is force click. We only want to execute this on the
            // initial transition to stage 2, and not for any repeated events.
            guard self.prevPressureStage < 2 else { return }
            prevPressureStage = event.stage
            guard event.stage == 2 else { return }

            // If the user has force click enabled then we do a quick look. There
            // is no public API for this as far as I can tell.
            guard UserDefaults.standard.bool(forKey: "com.apple.trackpad.forceClick") else { return }
            quickLook(with: event)
        }

        override func keyDown(with event: NSEvent) {
            // Octet's own `/` menu gets first refusal on agent panes.
            if OctetKeyHook.handleKeyDown(event) { return }
            guard let surface = self.surface else {
                self.interpretKeyEvents([event])
                return
            }

            // We need to translate the mods (maybe) to handle configs such as option-as-alt
            let translationModsEngine = TerminalEngine.eventModifierFlags(
                mods: ghostty_surface_key_translation_mods(
                    surface,
                    TerminalEngine.engineMods(event.modifierFlags)
                )
            )

            // There are hidden bits set in our event that matter for certain dead keys
            // so we can't use translationModsEngine directly. Instead, we just check
            // for exact states and set them.
            var translationMods = event.modifierFlags
            for flag in [NSEvent.ModifierFlags.shift, .control, .option, .command] {
                if translationModsEngine.contains(flag) {
                    translationMods.insert(flag)
                } else {
                    translationMods.remove(flag)
                }
            }

            // If the translation modifiers are not equal to our original modifiers
            // then we need to construct a new NSEvent. If they are equal we reuse the
            // old one. IMPORTANT: we MUST reuse the old event if they're equal because
            // this keeps things like Korean input working. There must be some object
            // equality happening in AppKit somewhere because this is required.
            let translationEvent: NSEvent
            if translationMods == event.modifierFlags {
                translationEvent = event
            } else {
                translationEvent = NSEvent.keyEvent(
                    with: event.type,
                    location: event.locationInWindow,
                    modifierFlags: translationMods,
                    timestamp: event.timestamp,
                    windowNumber: event.windowNumber,
                    context: nil,
                    characters: event.characters(byApplyingModifiers: translationMods) ?? "",
                    charactersIgnoringModifiers: event.charactersIgnoringModifiers ?? "",
                    isARepeat: event.isARepeat,
                    keyCode: event.keyCode
                ) ?? event
            }

            let action = event.isARepeat ? GHOSTTY_ACTION_REPEAT : GHOSTTY_ACTION_PRESS

            // By setting this to non-nil, we note that we're in a keyDown event. From here,
            // we call interpretKeyEvents so that we can handle complex input such as Korean
            // language.
            keyTextAccumulator = []
            defer { keyTextAccumulator = nil }

            // We need to know what the length of marked text was before this event to
            // know if these events cleared it.
            let markedTextBefore = markedText.length > 0

            // We need to know the keyboard layout before below because some keyboard
            // input events will change our keyboard layout and we don't want those
            // going to the terminal.
            let keyboardIdBefore: String? = if !markedTextBefore {
                KeyboardLayout.id
            } else {
                nil
            }

            // If we are in a keyDown then we don't need to redispatch a command-modded
            // key event (see docs for this field) so reset this to nil because
            // `interpretKeyEvents` may dispatch it.
            self.lastPerformKeyEvent = nil

            self.interpretKeyEvents([translationEvent])

            // If our keyboard changed from this we just assume an input method
            // grabbed it and do nothing.
            if !markedTextBefore && keyboardIdBefore != KeyboardLayout.id {
                return
            }

            // If we have marked text, we're in a preedit state. The order we
            // do this and the key event callbacks below doesn't matter since
            // we control the preedit state only through the preedit API.
            syncPreedit(clearIfNeeded: markedTextBefore)

            // We're composing if we have preedit (the obvious case). But we're also
            // composing if we don't have preedit and we had marked text before,
            // because this input probably just reset the preedit state. It shouldn't
            // be encoded. Example: Japanese begin composing, then press backspace
            // or ctrl+h. This should only cancel the composing state but not
            // actually delete the prior input characters (prior to the composing).
            let composing = markedText.length > 0 || markedTextBefore

            // The input method may commit all or part of the preedit text via
            // insertText while handling a key that should not itself be
            // encoded. Send that committed text separately, then only replay
            // keys that should still affect the terminal after committing.
            if markedTextBefore,
               let list = keyTextAccumulator,
               list.count > 0 {
                for text in list {
                    if TerminalEngine.SurfaceView.shouldSuppressComposingControlInput(
                        text,
                        composing: composing
                    ) {
                        continue
                    }

                    _ = committedPreeditTextAction(action, text: text)
                }

                if shouldReplayCommittedPreeditKey(translationEvent) {
                    _ = keyAction(
                        action,
                        event: event,
                        translationEvent: translationEvent,
                        composing: false
                    )
                }
                return
            }

            if let list = keyTextAccumulator, list.count > 0 {
                // Accumulated text from interpretKeyEvents (committed by the IME).
                for text in list {
                    // Drop bare control characters the IME accumulated while
                    // composing so they don't leak through to the terminal.
                    if TerminalEngine.SurfaceView.shouldSuppressComposingControlInput(
                        text,
                        composing: composing
                    ) {
                        continue
                    }

                    // We've composed a character; send it down. keyAction's
                    // default composing=false applies because this is the
                    // committed result of a composition, not in-progress preedit.
                    _ = keyAction(
                        action,
                        event: event,
                        translationEvent: translationEvent,
                        text: text
                    )
                }
            } else {
                // Raw control characters (e.g. ctrl+h) arriving during
                // composition belong to the IME, not the terminal.
                if TerminalEngine.SurfaceView.shouldSuppressComposingControlInput(
                    event.characters,
                    composing: composing
                ) {
                    return
                }

                // We have no accumulated text so this is a normal key event.
                _ = keyAction(
                    action,
                    event: event,
                    translationEvent: translationEvent,
                    text: translationEvent.engineCharacters,
                    composing: composing
                )
            }
        }

        override func keyUp(with event: NSEvent) {
            _ = keyAction(GHOSTTY_ACTION_RELEASE, event: event)
        }

        /// Records the timestamp of the last event to performKeyEquivalent that we need to save.
        /// We currently save all commands with command or control set.
        ///
        /// For command+key inputs, the AppKit input stack calls performKeyEquivalent to give us a chance
        /// to handle them first. If we return "false" then it goes through the standard AppKit responder chain.
        /// For an NSTextInputClient, that may redirect some commands _before_ our keyDown gets called.
        /// Concretely: Command+Period will do: performKeyEquivalent, doCommand ("cancel:"). In doCommand,
        /// we need to know that we actually want to handle that in keyDown, so we send it back through the
        /// event dispatch system and use this timestamp as an identity to know to actually send it to keyDown.
        ///
        /// Why not send it to keyDown always? Because if the user rebinds a command to something we
        /// actually handle then we do want the standard response chain to handle the key input. Unfortunately,
        /// we can't know what a command is bound to at a system level until we let it flow through the system.
        /// That's the crux of the problem.
        ///
        /// So, we have to send it back through if we didn't handle it.
        ///
        /// The best thing I could find was to store the event timestamp which has decent granularity
        /// and compare that. To further complicate things, some events are synthetic and have a zero
        /// timestamp so we have to protect against that. Fun!
        var lastPerformKeyEvent: TimeInterval?

        /// Special case handling for some control keys
        override func performKeyEquivalent(with event: NSEvent) -> Bool {
            // We only care about key down events. It might not even be possible
            // to receive any other event type here.
            guard event.type == .keyDown else { return false }

            // Only process events if we're focused. Some key events like C-/ macOS
            // appears to send to the first view in the hierarchy rather than the
            // the first responder (I don't know why). This prevents us from handling it.
            // Besides C-/, its important we don't process key equivalents if unfocused
            // because there are other event listeners for that (i.e. AppDelegate's
            // local event handler).
            if !focused {
                return false
            }

            // Octet: the app's menus (tabs, workspaces, sidebar) own Command
            // shortcuts. Disabled items (e.g. Copy with no handler) don't
            // consume the event, so cmd+c / cmd+v still reach the engine.
            if event.modifierFlags.contains(.command),
               NSApp.mainMenu?.performKeyEquivalent(with: event) == true {
                return true
            }

            // Get information about if this is a binding.
            let bindingFlags = surfaceModel.flatMap { surface in
                var engineEvent = event.engineKeyEvent(GHOSTTY_ACTION_PRESS)
                return (event.characters ?? "").withCString { ptr in
                    engineEvent.text = ptr
                    return surface.keyIsBinding(engineEvent)
                }
            }

            // If this is a binding then we want to perform it. (A full terminal app first
            // tries its app menu here; Octet has no such menu so the engine handles
            // bindings such as cmd+c / cmd+v directly.)
            if bindingFlags != nil {
                self.keyDown(with: event)
                return true
            }

            let equivalent: String
            switch event.charactersIgnoringModifiers {
            case "\r":
                // Pass C-<return> through verbatim
                // (prevent the default context menu equivalent)
                if !event.modifierFlags.contains(.control) {
                    return false
                }

                equivalent = "\r"

            case "/":
                // Treat C-/ as C-_. We do this because C-/ makes macOS make a beep
                // sound and we don't like the beep sound.
                if !event.modifierFlags.contains(.control) ||
                    !event.modifierFlags.isDisjoint(with: [.shift, .command, .option]) {
                    return false
                }

                equivalent = "_"

            default:
                // It looks like some part of AppKit sometimes generates synthetic NSEvents
                // with a zero timestamp. We never process these at this point. Concretely,
                // this happens for me when pressing Cmd+period with default bindings. This
                // binds to "cancel" which goes through AppKit to produce a synthetic "escape".
                if event.timestamp == 0 {
                    return false
                }

                // All of this logic here re: lastCommandEvent is to workaround some
                // nasty behavior. See the docs for lastCommandEvent for more info.

                // Ignore all other non-command events. This lets the event continue
                // through the AppKit event systems.
                if !event.modifierFlags.contains(.command) &&
                    !event.modifierFlags.contains(.control) {
                    // Reset since we got a non-command event.
                    lastPerformKeyEvent = nil
                    return false
                }

                // If we have a prior command binding and the timestamp matches exactly
                // then we pass it through to keyDown for encoding.
                if let lastPerformKeyEvent {
                    self.lastPerformKeyEvent = nil
                    if lastPerformKeyEvent == event.timestamp {
                        equivalent = event.characters ?? ""
                        break
                    }
                }

                lastPerformKeyEvent = event.timestamp
                return false
            }

            let finalEvent = NSEvent.keyEvent(
                with: .keyDown,
                location: event.locationInWindow,
                modifierFlags: event.modifierFlags,
                timestamp: event.timestamp,
                windowNumber: event.windowNumber,
                context: nil,
                characters: equivalent,
                charactersIgnoringModifiers: equivalent,
                isARepeat: event.isARepeat,
                keyCode: event.keyCode
            )

            self.keyDown(with: finalEvent!)
            return true
        }

        override func flagsChanged(with event: NSEvent) {
            let mod: UInt32
            switch event.keyCode {
            case 0x39: mod = GHOSTTY_MODS_CAPS.rawValue
            case 0x38, 0x3C: mod = GHOSTTY_MODS_SHIFT.rawValue
            case 0x3B, 0x3E: mod = GHOSTTY_MODS_CTRL.rawValue
            case 0x3A, 0x3D: mod = GHOSTTY_MODS_ALT.rawValue
            case 0x37, 0x36: mod = GHOSTTY_MODS_SUPER.rawValue
            default: return
            }

            // If we're in the middle of a preedit, don't do anything with mods.
            if hasMarkedText() { return }

            // The keyAction function will do this AGAIN below which sucks to repeat
            // but this is super cheap and flagsChanged isn't that common.
            let mods = TerminalEngine.engineMods(event.modifierFlags)

            // If the key that pressed this is active, its a press, else release.
            var action = GHOSTTY_ACTION_RELEASE
            if mods.rawValue & mod != 0 {
                // If the key is pressed, its slightly more complicated, because we
                // want to check if the pressed modifier is the correct side. If the
                // correct side is pressed then its a press event otherwise its a release
                // event with the opposite modifier still held.
                let sidePressed: Bool
                switch event.keyCode {
                case 0x3C:
                    sidePressed = event.modifierFlags.rawValue & UInt(NX_DEVICERSHIFTKEYMASK) != 0
                case 0x3E:
                    sidePressed = event.modifierFlags.rawValue & UInt(NX_DEVICERCTLKEYMASK) != 0
                case 0x3D:
                    sidePressed = event.modifierFlags.rawValue & UInt(NX_DEVICERALTKEYMASK) != 0
                case 0x36:
                    sidePressed = event.modifierFlags.rawValue & UInt(NX_DEVICERCMDKEYMASK) != 0
                default:
                    sidePressed = true
                }

                if sidePressed {
                    action = GHOSTTY_ACTION_PRESS
                }
            }

            _ = keyAction(action, event: event)
        }

        private func keyAction(
            _ action: ghostty_input_action_e,
            event: NSEvent,
            translationEvent: NSEvent? = nil,
            text: String? = nil,
            composing: Bool = false
        ) -> Bool {
            guard let surface = self.surface else { return false }

            var key_ev = event.engineKeyEvent(action, translationMods: translationEvent?.modifierFlags)
            key_ev.composing = composing

            // For text, we only encode UTF8 if we don't have a single control
            // character. Control characters are encoded by the engine itself.
            // Without this, `ctrl+enter` does the wrong thing.
            if let text, text.count > 0,
               let codepoint = text.utf8.first, codepoint >= 0x20 {
                return text.withCString { ptr in
                    key_ev.text = ptr
                    return ghostty_surface_key(surface, key_ev)
                }
            } else {
                return ghostty_surface_key(surface, key_ev)
            }
        }

        private func shouldReplayCommittedPreeditKey(_ event: NSEvent) -> Bool {
            guard let key = TerminalEngine.Input.Key(keyCode: event.keyCode) else { return false }
            switch key {
            case .arrowDown, .arrowRight, .arrowUp:
                return true
            case .arrowLeft:
                // Don't replay plain left-arrow because AppKit already leaves
                // the caret in place after Korean IMEs commit preedit text.
                return !event.modifierFlags.isDisjoint(with: [.shift, .control, .option, .command])
            default:
                return false
            }
        }

        private func committedPreeditTextAction(
            _ action: ghostty_input_action_e,
            text: String
        ) -> Bool {
            guard let surface = self.surface else { return false }

            var key_ev = ghostty_input_key_s()
            key_ev.action = action
            key_ev.keycode = 0
            key_ev.text = nil
            key_ev.composing = false
            key_ev.mods = GHOSTTY_MODS_NONE
            key_ev.consumed_mods = GHOSTTY_MODS_NONE
            key_ev.unshifted_codepoint = 0

            return text.withCString { ptr in
                key_ev.text = ptr
                return ghostty_surface_key(surface, key_ev)
            }
        }

        override func quickLook(with event: NSEvent) {
            guard let surface = self.surface else { return super.quickLook(with: event) }

            // Grab the text under the cursor
            var text = ghostty_text_s()
            guard ghostty_surface_quicklook_word(surface, &text) else { return super.quickLook(with: event) }
            defer { ghostty_surface_free_text(surface, &text) }
            guard text.text_len > 0  else { return super.quickLook(with: event) }

            // If we can get a font then we use the font. This should always work
            // since we always have a primary font.
            var attributes: [ NSAttributedString.Key: Any ] = [:]
            if let fontRaw = ghostty_surface_quicklook_font(surface) {
                // Memory management here is wonky: ghostty_surface_quicklook_font
                // will create a copy of a CTFont, Swift will auto-retain the
                // unretained value passed into the dict, so we release the original.
                let font = Unmanaged<CTFont>.fromOpaque(fontRaw)
                attributes[.font] = font.takeUnretainedValue()
                font.release()
            }

            // The engine's coordinate system is top-left, convert to bottom-left for AppKit
            let pt = NSPoint(x: text.tl_px_x, y: frame.size.height - text.tl_px_y)
            let str = NSAttributedString.init(string: String(cString: text.text), attributes: attributes)
            self.showDefinition(for: str, at: pt)
        }

        override func menu(for event: NSEvent) -> NSMenu? {
            // We only support right-click menus
            switch event.type {
            case .rightMouseDown:
                // Good
                break

            case .leftMouseDown:
                if !event.modifierFlags.contains(.control) {
                    return nil
                }

                // Octet: ⌃-click is the Mac's right-click, and the session
                // server always captures the mouse, so it opens Octet's menu
                // rather than reaching the pane.
                return OctetTerminalMenu.menu(for: self)

            default:
                return nil
            }

            return OctetTerminalMenu.menu(for: self)
        }

        // MARK: Menu Handlers

        private func performBindingAction(_ action: String) {
            guard let surface = self.surface else { return }
            if !ghostty_surface_binding_action(surface, action, UInt(action.lengthOfBytes(using: .utf8))) {
                TerminalEngine.logger.warning("action failed action=\(action, privacy: .public)")
            }
        }

        @IBAction func copy(_ sender: Any?) {
            if OctetKeyHook.prompt?.copySelection() == true { return }
            performBindingAction("copy_to_clipboard")
        }

        @IBAction func paste(_ sender: Any?) {
            if OctetKeyHook.paste() { return }
            performBindingAction("paste_from_clipboard")
        }

        @IBAction func pasteAsPlainText(_ sender: Any?) {
            if OctetKeyHook.paste(plainText: true) { return }
            performBindingAction("paste_from_clipboard")
        }

        @IBAction func pasteSelection(_ sender: Any?) {
            if OctetKeyHook.paste(from: .engineSelection, plainText: true) { return }
            performBindingAction("paste_from_selection")
        }

        @IBAction override func selectAll(_ sender: Any?) {
            if OctetKeyHook.prompt?.selectAll() == true { return }
            performBindingAction("select_all")
        }
    }

    /// The configuration for a surface. For any configuration not set, defaults will be chosen from
    /// the engine, usually from the terminal configuration.
    struct SurfaceConfiguration {
        /// Explicit font size to use in points
        var fontSize: Float32?

        /// Explicit working directory. This is normalized on assignment to
        /// remove any redundant and trailing path separators.
        var workingDirectory: String? {
            get { normalizedWorkingDirectory }
            set { normalizedWorkingDirectory = newValue.map { FilePath($0).string } }
        }
        private var normalizedWorkingDirectory: String?

        /// Explicit command to set
        var command: String?

        /// Environment variables to set for the terminal
        var environmentVariables: [String: String] = [:]

        /// Extra input to send as stdin
        var initialInput: String?

        /// Wait after the command
        var waitAfterCommand: Bool = false

        /// Context for surface creation
        var context: ghostty_surface_context_e = GHOSTTY_SURFACE_CONTEXT_WINDOW

        init() {}

        /// Provides a C-compatible engine configuration within a closure. The configuration
        /// and all its string pointers are only valid within the closure.
        func withCValue<T>(view: SurfaceView, _ body: (inout ghostty_surface_config_s) throws -> T) rethrows -> T {
            var config = ghostty_surface_config_new()
            config.userdata = Unmanaged.passUnretained(view).toOpaque()
            config.platform_tag = GHOSTTY_PLATFORM_MACOS
            config.platform = ghostty_platform_u(macos: ghostty_platform_macos_s(
                nsview: Unmanaged.passUnretained(view).toOpaque()
            ))
            config.scale_factor = Double(NSScreen.main?.backingScaleFactor ?? 2.0)

            // Zero is our default value that means to inherit the font size.
            config.font_size = fontSize ?? 0

            // Set wait after command
            config.wait_after_command = waitAfterCommand

            // Set context
            config.context = context

            // Use withCString to ensure strings remain valid for the duration of the closure
            return try workingDirectory.withCString { cWorkingDir in
                config.working_directory = cWorkingDir

                return try command.withCString { cCommand in
                    config.command = cCommand

                    return try initialInput.withCString { cInput in
                        config.initial_input = cInput

                        // Convert dictionary to arrays for easier processing
                        let keys = Array(environmentVariables.keys)
                        let values = Array(environmentVariables.values)

                        // Create C strings for all keys and values
                        return try keys.withCStrings { keyCStrings in
                            return try values.withCStrings { valueCStrings in
                                // Create array of ghostty_env_var_s
                                var envVars = [ghostty_env_var_s]()
                                envVars.reserveCapacity(environmentVariables.count)
                                for i in 0..<environmentVariables.count {
                                    envVars.append(ghostty_env_var_s(
                                        key: keyCStrings[i],
                                        value: valueCStrings[i]
                                    ))
                                }

                                return try envVars.withUnsafeMutableBufferPointer { buffer in
                                    config.env_vars = buffer.baseAddress
                                    config.env_var_count = environmentVariables.count
                                    return try body(&config)
                                }
                            }
                        }
                    }
                }
            }
        }
    }
}

// MARK: - NSTextInputClient

extension TerminalEngine.SurfaceView: NSTextInputClient {
    func hasMarkedText() -> Bool {
        return markedText.length > 0
    }

    func markedRange() -> NSRange {
        guard markedText.length > 0 else { return NSRange() }
        return NSRange(0...(markedText.length-1))
    }

    func selectedRange() -> NSRange {
        guard let surface = self.surface else { return NSRange() }

        // Get our range from the engine API. There is a race condition between getting the
        // range and actually using it since our selection may change but there isn't a good
        // way I can think of to solve this for AppKit.
        var text = ghostty_text_s()
        guard ghostty_surface_read_selection(surface, &text) else { return NSRange() }
        defer { ghostty_surface_free_text(surface, &text) }
        return NSRange(location: Int(text.offset_start), length: Int(text.offset_len))
    }

    func setMarkedText(_ string: Any, selectedRange: NSRange, replacementRange: NSRange) {
        switch string {
        case let v as NSAttributedString:
            self.markedText = NSMutableAttributedString(attributedString: v)

        case let v as String:
            self.markedText = NSMutableAttributedString(string: v)

        default:
            print("unknown marked text: \(string)")
        }

        // If we're not in a keyDown event, then we want to update our preedit
        // text immediately. This can happen due to external events, for example
        // changing keyboard layouts while composing: (1) set US intl (2) type '
        // to enter dead key state (3)
        if keyTextAccumulator == nil {
            syncPreedit()
        }
    }

    func unmarkText() {
        if self.markedText.length > 0 {
            self.markedText.mutableString.setString("")
            syncPreedit()
        }
    }

    func validAttributesForMarkedText() -> [NSAttributedString.Key] {
        return []
    }

    func attributedSubstring(forProposedRange range: NSRange, actualRange: NSRangePointer?) -> NSAttributedString? {
        guard let surface = self.surface else { return nil }

        // If the range is empty then we don't need to return anything
        guard range.length > 0 else { return nil }

        // I used to do a bunch of testing here that the range requested matches the
        // selection range or contains it but a lot of macOS system behaviors request
        // bogus ranges I truly don't understand so we just always return the
        // attributed string containing our selection which is... weird but works?

        // Get our selection text
        var text = ghostty_text_s()
        guard ghostty_surface_read_selection(surface, &text) else { return nil }
        defer { ghostty_surface_free_text(surface, &text) }

        // If we can get a font then we use the font. This should always work
        // since we always have a primary font.
        var attributes: [ NSAttributedString.Key: Any ] = [:]
        if let fontRaw = ghostty_surface_quicklook_font(surface) {
            // Memory management here is wonky: ghostty_surface_quicklook_font
            // will create a copy of a CTFont, Swift will auto-retain the
            // unretained value passed into the dict, so we release the original.
            let font = Unmanaged<CTFont>.fromOpaque(fontRaw)
            attributes[.font] = font.takeUnretainedValue()
            font.release()
        }

        return .init(string: String(cString: text.text), attributes: attributes)
    }

    func characterIndex(for point: NSPoint) -> Int {
        return 0
    }

    func firstRect(forCharacterRange range: NSRange, actualRange: NSRangePointer?) -> NSRect {
        guard let surface = self.surface else {
            return NSRect(x: frame.origin.x, y: frame.origin.y, width: 0, height: 0)
        }

        // The engine will tell us where it thinks an IME keyboard should render.
        var x: Double = 0
        var y: Double = 0
        var width: Double = cellSize.width
        var height: Double = cellSize.height

        // QuickLook never gives us a matching range to our selection so if we detect
        // this then we return the top-left selection point rather than the cursor point.
        // This is hacky but I can't think of a better way to get the right IME vs. QuickLook
        // point right now. I'm sure I'm missing something fundamental...
        if range.length > 0 && range != self.selectedRange() {
            // QuickLook
            var text = ghostty_text_s()
            if ghostty_surface_read_selection(surface, &text) {
                // The -2/+2 here is subjective. QuickLook seems to offset the rectangle
                // a bit and I think these small adjustments make it look more natural.
                x = text.tl_px_x - 2
                y = text.tl_px_y + 2

                // Free our text
                ghostty_surface_free_text(surface, &text)
            } else {
                ghostty_surface_ime_point(surface, &x, &y, &width, &height)
            }
        } else {
            ghostty_surface_ime_point(surface, &x, &y, &width, &height)
        }
        if range.length == 0, width > 0 {
            // This fixes #8493 while speaking
            // My guess is that positive width doesn't make sense
            // for the dictation microphone indicator
            width = 0
            x += cellSize.width * Double(range.location + range.length)
        }
        // Engine coordinates are in top-left (0, 0) so we have to convert to
        // bottom-left since that is what UIKit expects
        let viewRect = NSRect(
            x: x,
            y: frame.size.height - y,
            width: width,
            height: max(height, cellSize.height))

        // Convert the point to the window coordinates
        let winRect = self.convert(viewRect, to: nil)

        // Convert from view to screen coordinates
        guard let window = self.window else { return winRect }
        return window.convertToScreen(winRect)
    }

    func insertText(_ string: Any, replacementRange: NSRange) {
        // We must have an associated event
        guard NSApp.currentEvent != nil else { return }
        guard let surfaceModel else { return }

        // We want the string view of the any value
        var chars = ""
        switch string {
        case let v as NSAttributedString:
            chars = v.string
        case let v as String:
            chars = v
        default:
            return
        }

        let hadMarkedText = hasMarkedText()

        // If insertText is called, our preedit must be over.
        unmarkText()

        // If we have an accumulator we're in another key event so we just
        // accumulate and return.
        if var acc = keyTextAccumulator {
            acc.append(chars)
            keyTextAccumulator = acc
            return
        }

        if hadMarkedText, !chars.isEmpty {
            // Send preedit commits as key events instead of raw text for
            // keybind interpretation by programs.
            _ = committedPreeditTextAction(GHOSTTY_ACTION_PRESS, text: chars)
            return
        }

        surfaceModel.sendText(chars)
    }

    /// This function needs to exist for two reasons:
    /// 1. Prevents an audible NSBeep for unimplemented actions.
    /// 2. Allows us to properly encode super+key input events that we don't handle
    override func doCommand(by selector: Selector) {
        // If we are being processed by performKeyEquivalent with a command binding,
        // we send it back through the event system so it can be encoded.
        if let lastPerformKeyEvent,
           let current = NSApp.currentEvent,
           lastPerformKeyEvent == current.timestamp {
            NSApp.sendEvent(current)
        }
    }

    /// Sync the preedit state based on the markedText value to the engine
    private func syncPreedit(clearIfNeeded: Bool = true) {
        guard let surface else { return }

        if markedText.length > 0 {
            let str = markedText.string
            let len = str.utf8CString.count
            if len > 0 {
                markedText.string.withCString { ptr in
                    // Subtract 1 for the null terminator
                    ghostty_surface_preedit(surface, ptr, UInt(len - 1))
                }
            }
        } else if clearIfNeeded {
            // If we had marked text before but don't now, we're no longer
            // in a preedit state so we can clear it.
            ghostty_surface_preedit(surface, nil, 0)
        }
    }

    /// True when `text` is a single C0 control character (U+0000-U+001F)
    /// arriving while the IME is composing. Such input belongs to the IME
    /// and must not be forwarded to the terminal.
    static func shouldSuppressComposingControlInput(
        _ text: String?,
        composing: Bool
    ) -> Bool {
        guard composing, let text else { return false }
        let scalars = text.unicodeScalars
        guard let scalar = scalars.first,
              scalars.index(after: scalars.startIndex) == scalars.endIndex else {
            return false
        }
        return scalar.value < 0x20
    }
}

// MARK: Services

// https://developer.apple.com/library/archive/documentation/Cocoa/Conceptual/SysServices/Articles/using.html
extension TerminalEngine.SurfaceView: NSServicesMenuRequestor {
    override func validRequestor(
        forSendType sendType: NSPasteboard.PasteboardType?,
        returnType: NSPasteboard.PasteboardType?
    ) -> Any? {
        // Types we can receive
        let receivable: [NSPasteboard.PasteboardType] = [.string, .init("public.utf8-plain-text")]

        // Types that we can send. Currently the same as receivable but I'm separating
        // this out so we can modify this in the future.
        let sendable: [NSPasteboard.PasteboardType] = receivable

        // The sendable types that require a selection (currently all)
        let sendableRequiresSelection = sendable

        // If we expect no data to be sent/received we can obviously handle it (that's
        // the nil check), otherwise it must conform to the types we support on both sides.
        if (returnType == nil || receivable.contains(returnType!)) &&
            (sendType == nil || sendable.contains(sendType!)) {
            // If we're expected to send back a type that requires selection, then
            // verify that we have a selection. We do this within this block because
            // validateRequestor is called a LOT and we want to prevent unnecessary
            // performance hits because `ghostty_surface_has_selection` isn't free.
            if let sendType, sendableRequiresSelection.contains(sendType) {
                if surface == nil || !ghostty_surface_has_selection(surface) {
                    return super.validRequestor(forSendType: sendType, returnType: returnType)
                }
            }

            return self
        }

        return super.validRequestor(forSendType: sendType, returnType: returnType)
    }

    func writeSelection(
        to pboard: NSPasteboard,
        types: [NSPasteboard.PasteboardType]
    ) -> Bool {
        guard let surface = self.surface else { return false }

        // Read the selection
        var text = ghostty_text_s()
        guard ghostty_surface_read_selection(surface, &text) else { return false }
        defer { ghostty_surface_free_text(surface, &text) }

        pboard.declareTypes([.string], owner: nil)
        pboard.setString(String(cString: text.text), forType: .string)
        return true
    }

    func readSelection(from pboard: NSPasteboard) -> Bool {
        if OctetKeyHook.paste(from: pboard, plainText: true) { return true }
        guard let str = pboard.getOpinionatedStringContents() else { return false }

        let len = str.utf8CString.count
        if len == 0 { return true }
        str.withCString { ptr in
            // len includes the null terminator so we do len - 1
            ghostty_surface_text(surface, ptr, UInt(len - 1))
        }

        return true
    }
}

// MARK: NSMenuItemValidation

extension TerminalEngine.SurfaceView: NSMenuItemValidation {
    func validateMenuItem(_ item: NSMenuItem) -> Bool {
        switch item.action {
        case #selector(pasteSelection):
            let pb = NSPasteboard.engineSelection
            guard let str = pb.getOpinionatedStringContents() else { return false }
            return !str.isEmpty

        case #selector(copy(_:)):
            if OctetKeyHook.prompt?.isActive == true,
               OctetKeyHook.prompt?.line.selectedText != nil { return true }
            // We only enable copy menu item when there're actual selected text
            if let text = self.accessibilitySelectedText(), text.count > 0 {
                return true
            } else {
                return false
            }

        default:
            return true
        }
    }
}

// MARK: NSDraggingDestination

extension TerminalEngine.SurfaceView {
    static let dropTypes: Set<NSPasteboard.PasteboardType> = [
        .string,
        .fileURL,
    ]

    override func draggingEntered(_ sender: any NSDraggingInfo) -> NSDragOperation {
        guard let types = sender.draggingPasteboard.types else { return [] }

        // If the dragging object contains none of our types then we return none.
        // This shouldn't happen because AppKit should guarantee that we only
        // receive types we registered for but its good to check.
        if Set(types).isDisjoint(with: Self.dropTypes) {
            return []
        }

        // We use copy to get the proper icon
        return .copy
    }

    override func performDragOperation(_ sender: any NSDraggingInfo) -> Bool {
        let pb = sender.draggingPasteboard

        let content = pb.getOpinionatedStringContents()

        if let content {
            if OctetKeyHook.prompt?.insertPastedText(content) == true { return true }
            DispatchQueue.main.async {
                self.insertText(
                    content,
                    replacementRange: NSRange(location: 0, length: 0)
                )
            }
            return true
        }

        return false
    }
}

// MARK: Accessibility

extension TerminalEngine.SurfaceView {
    override func isAccessibilityElement() -> Bool {
        return true
    }

    override func accessibilityRole() -> NSAccessibility.Role? {
        return .textArea
    }

    override func accessibilityHelp() -> String? {
        return "Terminal content area"
    }

    override func accessibilityValue() -> Any? {
        return cachedScreenContents.get()
    }

    override func accessibilitySelectedTextRange() -> NSRange {
        return selectedRange()
    }

    override func accessibilityNumberOfCharacters() -> Int {
        return cachedScreenContents.get().count
    }

    override func accessibilityVisibleCharacterRange() -> NSRange {
        return NSRange(location: 0, length: cachedScreenContents.get().count)
    }

    override func accessibilityLine(for index: Int) -> Int {
        let content = cachedScreenContents.get()
        return String(content.prefix(index)).components(separatedBy: .newlines).count - 1
    }

    override func accessibilityString(for range: NSRange) -> String? {
        let content = cachedScreenContents.get()
        guard let swiftRange = Range(range, in: content) else { return nil }
        return String(content[swiftRange])
    }

    override func accessibilityAttributedString(for range: NSRange) -> NSAttributedString? {
        guard let surface = self.surface, let plain = accessibilityString(for: range) else { return nil }
        var attributes: [NSAttributedString.Key: Any] = [:]
        if let fontRaw = ghostty_surface_quicklook_font(surface) {
            let font = Unmanaged<CTFont>.fromOpaque(fontRaw)
            attributes[.font] = font.takeUnretainedValue()
            font.release()
        }
        return NSAttributedString(string: plain, attributes: attributes)
    }

    /// The viewport's text, minus the rows Octet clips off the top (the session server's
    /// own tab row), so a screen reader hears only what's on screen.
    fileprivate func readVisibleText() -> String {
        guard let surface = self.surface else { return "" }
        var text = ghostty_text_s()
        let sel = ghostty_selection_s(
            top_left: ghostty_point_s(tag: GHOSTTY_POINT_VIEWPORT, coord: GHOSTTY_POINT_COORD_TOP_LEFT, x: 0, y: 0),
            bottom_right: ghostty_point_s(tag: GHOSTTY_POINT_VIEWPORT, coord: GHOSTTY_POINT_COORD_BOTTOM_RIGHT, x: 0, y: 0),
            rectangle: false)
        guard ghostty_surface_read_text(surface, sel, &text) else { return "" }
        defer { ghostty_surface_free_text(surface, &text) }
        let lines = String(cString: text.text).components(separatedBy: "\n")
        return lines.dropFirst(min(EngineSession.hiddenTopRows, lines.count)).joined(separator: "\n")
    }

    /// Returns the currently selected text as a string.
    override func accessibilitySelectedText() -> String? {
        guard let surface = self.surface else { return nil }

        // Attempt to read the selection
        var text = ghostty_text_s()
        guard ghostty_surface_read_selection(surface, &text) else { return nil }
        defer { ghostty_surface_free_text(surface, &text) }

        let str = String(cString: text.text)
        return str.isEmpty ? nil : str
    }
}

// MARK: Helpers (NSScreen)

extension NSScreen {
    /// The unique CoreGraphics display ID for this screen.
    var displayID: UInt32? {
        deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? UInt32
    }
}

/// Caches a value briefly, evicting it automatically when the time is up.
/// Shared helper for the surface view.
final class CachedValue<T> {
    private var value: T?
    private let fetch: () -> T
    private let duration: Duration
    private var expiryTask: Task<Void, Never>?

    init(duration: Duration, fetch: @escaping () -> T) {
        self.duration = duration
        self.fetch = fetch
    }

    deinit {
        expiryTask?.cancel()
    }

    func get() -> T {
        if let value { return value }
        let result = fetch()
        let expires = ContinuousClock.now + duration
        value = result
        expiryTask = Task { [weak self] in
            do {
                try await Task.sleep(until: expires)
                self?.value = nil
                self?.expiryTask = nil
            } catch {}
        }
        return result
    }
}
