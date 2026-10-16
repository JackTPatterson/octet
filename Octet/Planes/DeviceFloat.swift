import AppKit
import Combine
import SwiftUI

/// T3 Code's floating device mini-player: the device's live screen in a
/// small window over everything, so an app can be watched and driven from
/// the terminal. One at a time. It shows the plane's own model, so the
/// plane and the float never stream the same device twice.
@MainActor
final class DeviceFloat: NSObject, NSWindowDelegate {
    static let shared = DeviceFloat()

    static let frameKey = "octet.deviceFloat.frame"

    /// A Device plane that's on screen somewhere, and how to bring it to front.
    private struct Entry {
        weak var model: DeviceHubModel?
        let showPlane: () -> Void
    }

    private var entries: [String: Entry] = [:]
    private var panel: DeviceFloatPanel?
    private var hosting: NSHostingView<DeviceFloatView>?
    private(set) var planeId: String?
    private var model: DeviceHubModel?
    private var watching: Set<AnyCancellable> = []
    /// The aspect the window keeps: the screen as input sees it, else the frame.
    private var screen: CGSize = .zero

    var isShowing: Bool { panel?.isVisible == true && model != nil }

    // MARK: Planes

    func register(planeId: String, model: DeviceHubModel, showPlane: @escaping () -> Void) {
        entries[planeId] = Entry(model: model, showPlane: showPlane)
    }

    /// The plane closed (or its window did): its float goes with it, since
    /// Open in Panel would have nowhere to go.
    func unregister(planeId: String) {
        entries[planeId] = nil
        if self.planeId == planeId { close() }
    }

    /// The right panel is being hidden with this plane in front. A device
    /// that's streaming moves into the float rather than going dark, as
    /// T3 Code does. Called from `UIState` before the plane hears it's
    /// hidden, so the stream is handed over rather than restarted.
    func panelHiding(planeId: String) {
        guard let model = entries[planeId]?.model, model.streaming, !model.floating else { return }
        float(planeId: planeId)
    }

    // MARK: Showing

    /// Floats this plane's device, replacing any other float.
    func float(planeId: String) {
        guard let model = entries[planeId]?.model, model.current != nil else { return }
        if self.planeId != planeId { close() }
        self.planeId = planeId
        self.model = model
        model.setFloating(true)
        let panel = panel ?? makePanel()
        hosting?.rootView = DeviceFloatView(model: model, openInPanel: { [weak self] in self?.openInPanel() },
                                            close: { [weak self] in self?.close() })
        screen = Self.aspect(model)
        place(panel, platform: model.current?.platform ?? .ios)
        watch(model)
        panel.orderFrontRegardless()
    }

    /// Closes the float and stops its stream; the device keeps running.
    func close() {
        watching.removeAll()
        if let panel, panel.isVisible {
            save(panel)
            panel.orderOut(nil)
        }
        model?.setFloating(false)
        model = nil
        planeId = nil
    }

    /// Back to the plane: the panel shows it and the stream carries on there.
    func openInPanel() {
        guard let planeId, let entry = entries[planeId], let model = entry.model else { return close() }
        entry.showPlane()
        // The plane is in front now; say so before letting go of the float,
        // so the stream is handed over rather than stopped and restarted.
        model.setVisible(true)
        close()
        NSApp.activate(ignoringOtherApps: true)
    }

    #if DEBUG
    private static var debugHookRan = false

    /// Every restored window runs the launch hooks; only the first opens a
    /// plane, so one device isn't streamed by two windows.
    static func debugClaimHook() -> Bool {
        defer { debugHookRan = true }
        return !debugHookRan
    }
    /// The scripted walkthrough keeps the hover pill up, so snapshots show it.
    static let debugPill = ProcessInfo.processInfo.environment["OCTET_DEVICE_FLOAT_SCRIPT"] != nil

    /// Verification hook for "planes:devicefloat:<id>": runs `then` once the
    /// plane's device is streaming, checking each second for two minutes,
    /// and logs the float's window so it can be captured.
    static func debugWhenStreaming(planeId: String, attempt: Int = 0, then: @escaping () -> Void) {
        DispatchQueue.main.asyncAfter(deadline: .now() + 1) {
            guard shared.entries[planeId]?.model?.streaming == true else {
                if attempt < 120 { debugWhenStreaming(planeId: planeId, attempt: attempt + 1, then: then) }
                return
            }
            // A second of video first, so the float opens on a real frame.
            DispatchQueue.main.asyncAfter(deadline: .now() + 1) {
                then()
                if let panel = shared.panel {
                    NSLog("octet.deviceFloat window=%d frame=%@ visible=%d", panel.windowNumber,
                          NSStringFromRect(panel.frame), panel.isVisible ? 1 : 0)
                }
                if let folder = ProcessInfo.processInfo.environment["OCTET_DEVICE_FLOAT_SCRIPT"] {
                    shared.debugScript(planeId: planeId, folder: folder)
                }
            }
        }
    }

    /// OCTET_DEVICE_FLOAT_SCRIPT=<folder>: walks the float through its
    /// states a few seconds apart, logging each and snapshotting the window
    /// into the folder: a tap on the screen, Close with the panel hidden
    /// (the stream stops), floating again from the menu (it restarts),
    /// Open in Panel (the same stream carries on), floating once more, then
    /// Close with the plane in front (the plane keeps the stream).
    private func debugScript(planeId: String, folder: String) {
        func log(_ step: String) {
            let model = entries[planeId]?.model
            NSLog("octet.deviceFloat step=%@ showing=%d floating=%d streaming=%d", step, isShowing ? 1 : 0,
                  model?.floating == true ? 1 : 0, model?.streaming == true ? 1 : 0)
        }
        func snapshot(_ name: String) {
            guard let view = panel?.contentView, let layer = view.layer,
                  let rep = view.bitmapImageRepForCachingDisplay(in: view.bounds),
                  let context = NSGraphicsContext(bitmapImageRep: rep) else { return }
            // The bitmap is bottom-up; the layers are top-down.
            context.cgContext.translateBy(x: 0, y: view.bounds.height)
            context.cgContext.scaleBy(x: 1, y: -1)
            layer.render(in: context.cgContext)
            try? rep.representation(using: .png, properties: [:])?
                .write(to: URL(fileURLWithPath: folder).appendingPathComponent(name + ".png"))
        }
        /// Clicks where an iPhone home screen keeps Settings (right column,
        /// halfway down), so the tap visibly opens something.
        func tapScreen() {
            guard let panel, let screen = panel.contentView.flatMap({ Self.find(DeviceScreenNSView.self, in: $0) }) else { return }
            let point = screen.convert(CGPoint(x: screen.bounds.width * 0.83, y: screen.bounds.height * 0.5), to: nil)
            for type in [NSEvent.EventType.leftMouseDown, .leftMouseUp] {
                if let event = NSEvent.mouseEvent(with: type, location: point, modifierFlags: [], timestamp: 0,
                                                  windowNumber: panel.windowNumber, context: nil, eventNumber: 0,
                                                  clickCount: 1, pressure: 1) {
                    panel.sendEvent(event)
                }
            }
        }
        let steps: [(Double, () -> Void)] = [
            (2, { log("floated"); snapshot("float") }),
            (4, { tapScreen(); log("tapped") }),
            (8, { snapshot("after-tap"); self.close(); log("closed-hidden") }),
            (12, { self.float(planeId: planeId); log("menu-float") }),
            (16, { self.openInPanel(); log("open-in-panel") }),
            (20, { self.float(planeId: planeId); log("menu-float-again") }),
            (24, { self.close(); log("closed") }),
        ]
        for (delay, step) in steps { DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: step) }
    }

    private static func find<T: NSView>(_ type: T.Type, in view: NSView) -> T? {
        if let match = view as? T { return match }
        for child in view.subviews { if let match = find(type, in: child) { return match } }
        return nil
    }
    #endif

    // MARK: Window

    private func makePanel() -> DeviceFloatPanel {
        let panel = DeviceFloatPanel(contentRect: CGRect(x: 0, y: 0, width: DeviceFloatGeometry.width, height: 600),
                                     styleMask: [.borderless, .nonactivatingPanel, .resizable],
                                     backing: .buffered, defer: true)
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true
        panel.level = .floating
        panel.isFloatingPanel = true
        // A click types into the screen without taking Octet's focus away
        // from wherever it is, the way a mini-player should.
        panel.becomesKeyOnlyIfNeeded = false
        panel.hidesOnDeactivate = false
        panel.isMovableByWindowBackground = true
        panel.isReleasedWhenClosed = false
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        panel.minSize = CGSize(width: DeviceFloatGeometry.minWidth, height: DeviceFloatGeometry.minWidth)
        panel.title = "Floating Device"
        panel.delegate = self
        let hosting = NSHostingView(rootView: DeviceFloatView(model: nil, openInPanel: {}, close: {}))
        hosting.sizingOptions = []
        panel.contentView = hosting
        self.panel = panel
        self.hosting = hosting
        return panel
    }

    private func place(_ panel: NSPanel, platform: DeviceInfo.Platform) {
        let saved = UserDefaults.standard.string(forKey: Self.frameKey).map(NSRectFromString)
        let display = saved.flatMap { rect in NSScreen.screens.first { $0.visibleFrame.intersects(rect) } }
            ?? NSApp.keyWindow?.screen ?? NSScreen.main
        let visible = display?.visibleFrame ?? CGRect(x: 0, y: 0, width: 1440, height: 900)
        let frame = DeviceFloatGeometry.frame(saved: panel.isVisible ? panel.frame : saved, screen: screen, visible: visible)
        panel.setFrame(frame, display: true)
        shape(panel, platform: platform)
    }

    private func shape(_ panel: NSPanel, platform: DeviceInfo.Platform) {
        hosting?.rootView.cornerRadius = DeviceFloatGeometry.cornerRadius(size: panel.frame.size, platform: platform)
        panel.invalidateShadow()
    }

    private func save(_ panel: NSPanel) {
        UserDefaults.standard.set(NSStringFromRect(panel.frame), forKey: Self.frameKey)
    }

    /// The screen's size as input knows it (it follows Android's rotation),
    /// else the last frame's.
    private static func aspect(_ model: DeviceHubModel) -> CGSize {
        if let screen = model.screen, screen.width > 0, screen.height > 0 { return screen }
        return model.frames.size
    }

    /// Follows the device: a rotation reshapes the window, and the device
    /// going away (powered off, another chosen) closes it.
    private func watch(_ model: DeviceHubModel) {
        watching.removeAll()
        model.$phase.dropFirst().sink { [weak self] phase in
            switch phase {
            case .picker, .stopped, .failed: DispatchQueue.main.async { self?.close() }
            default: break
            }
        }.store(in: &watching)
        Publishers.Merge(model.$screen.map { _ in () }, model.frames.$image.map { _ in () })
            .receive(on: DispatchQueue.main)
            .sink { [weak self, weak model] in
                guard let self, let model, let panel = self.panel, panel.isVisible else { return }
                let aspect = Self.aspect(model)
                guard aspect.width > 0, aspect.height > 0,
                      abs(aspect.width / aspect.height - self.screenRatio) > 0.01 else { return }
                self.screen = aspect
                let top = panel.frame.maxY
                var frame = panel.frame
                frame.size = DeviceFloatGeometry.size(screen: aspect, width: frame.width)
                frame.origin.y = top - frame.height
                panel.setFrame(frame, display: true, animate: false)
                self.shape(panel, platform: model.current?.platform ?? .ios)
            }
            .store(in: &watching)
    }

    private var screenRatio: CGFloat {
        let size = screen.width > 0 && screen.height > 0 ? screen : DeviceFloatGeometry.fallbackScreen
        return size.width / size.height
    }

    // MARK: NSWindowDelegate

    func windowWillResize(_ sender: NSWindow, to frameSize: NSSize) -> NSSize {
        DeviceFloatGeometry.resize(from: sender.frame.size, to: frameSize, screen: screen)
    }

    func windowDidResize(_ notification: Notification) {
        guard let panel else { return }
        shape(panel, platform: model?.current?.platform ?? .ios)
    }

    func windowDidEndLiveResize(_ notification: Notification) {
        if let panel { save(panel) }
    }

    func windowDidMove(_ notification: Notification) {
        if let panel, panel.isVisible { save(panel) }
    }
}

/// Borderless, but can take the keyboard so typing reaches the device.
final class DeviceFloatPanel: NSPanel {
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }
}

// MARK: - View

/// The float's content: the live screen in a dark card whose margin moves
/// the window, and a pill of two buttons on hover.
struct DeviceFloatView: View {
    let model: DeviceHubModel?
    let openInPanel: () -> Void
    let close: () -> Void
    var cornerRadius: CGFloat = DeviceFloatGeometry.cornerRadius
    @State private var hovered = false

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
        ZStack(alignment: .top) {
            DeviceFloatDragArea()
            if let model {
                DeviceFloatScreen(model: model, frames: model.frames)
                    .padding(DeviceFloatGeometry.inset)
            }
            if showsPill {
                pill
                    .padding(.top, 10)
                    .transition(.opacity)
            }
        }
        .background(shape.fill(Color.black))
        .clipShape(shape)
        .overlay(shape.strokeBorder(Theme.border, lineWidth: 1))
        .onHover { hovering in
            MotionPreferences.shared.perform(.sidebar) { hovered = hovering }
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Floating device")
    }

    private var showsPill: Bool {
        #if DEBUG
        if DeviceFloat.debugPill { return true }
        #endif
        return hovered
    }

    private var pill: some View {
        HStack(spacing: 2) {
            OctetIconButton(icon: "sidebar.right", help: "Open in Panel", action: openInPanel)
            OctetIconButton(icon: "xmark", help: "Close Floating Preview", action: close)
        }
        .padding(3)
        .octetGlass(cornerRadius: 15)
    }
}

/// The screen itself, interactive as in the plane, or a line saying why
/// it isn't there yet.
private struct DeviceFloatScreen: View {
    @ObservedObject var model: DeviceHubModel
    @ObservedObject var frames: DeviceFrameStore

    var body: some View {
        if let device = model.current {
            ZStack {
                DeviceScreenView(frames: frames, tablet: device.isTablet, interactive: model.inputAvailable,
                                 send: model.send, type: model.type)
                if frames.image == nil || model.noVideo {
                    VStack(spacing: 8) {
                        Text(model.noVideo ? "No video from \(device.name)" : "Connecting video…")
                            .font(Theme.captionFont)
                            .foregroundStyle(.white.opacity(0.6))
                        if model.noVideo {
                            OctetButton(title: "Reconnect", icon: "arrow.clockwise", compact: true) { model.reconnect() }
                        } else {
                            LoadingLine(width: 80)
                        }
                    }
                    .padding(12)
                }
            }
        }
    }
}

/// The card's margin: dragging it moves the window, since the screen
/// itself takes drags as swipes.
private struct DeviceFloatDragArea: NSViewRepresentable {
    func makeNSView(context: Context) -> NSView { DragView() }
    func updateNSView(_ nsView: NSView, context: Context) {}

    private final class DragView: NSView {
        override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
        override func mouseDown(with event: NSEvent) { window?.performDrag(with: event) }
    }
}
