import AppKit
import Combine
import GhosttyKit

/// Sends links clicked in a terminal to the Browser plane when they're a dev
/// server on this Mac or the local network, after T3 Code's
/// `openTerminalLinkInPreview`. Other links, and ⇧⌘-clicks, open as before.
@MainActor
enum TerminalLinkRouter {
    /// Whether a link should go to the Browser plane rather than out.
    static func wantsPreview(_ url: URL, modifiers: NSEvent.ModifierFlags = NSEvent.modifierFlags) -> Bool {
        guard SettingsStore.shared.values.previewTerminalLinks, PreviewLink.isLocal(url) else { return false }
        // ⇧ asks for the real browser, as T3 Code's "force browser" does.
        return !modifiers.contains(.shift)
    }

    /// Opens `url` in the Browser plane of the window `view` is in. False
    /// when it isn't one the plane takes, so the caller opens it as usual.
    @discardableResult
    static func open(_ url: URL, from view: NSView?) -> Bool {
        guard wantsPreview(url) else { return false }
        guard let ui = ui(for: view?.window) else { return false }
        ui.openInBrowserPlane(PreviewLink.loadable(url))
        return true
    }

    static func ui(for window: NSWindow?) -> UIState? {
        let registry = WindowRegistry.shared
        if let window, let context = registry.windows.first(where: { $0.nsWindow === window }) { return context.ui }
        return registry.key?.ui
    }
}

extension TerminalEngine.SurfaceView {
    /// With "open with a plain click" on, a click (no drag, no modifiers) on
    /// a local address opens it in the Browser plane. Ghostty itself only
    /// opens links on ⌘-click, so the address is read off the clicked row.
    @MainActor func openLocalLinkOnPlainClick(_ event: NSEvent, pressedAt: NSPoint?) {
        let settings = SettingsStore.shared.values
        guard settings.previewTerminalLinks, settings.previewLinksOnPlainClick,
              event.clickCount == 1,
              event.modifierFlags.intersection([.command, .shift, .option, .control]).isEmpty,
              let surface, !ghostty_surface_mouse_captured(surface), !ghostty_surface_has_selection(surface) else { return }
        let point = convert(event.locationInWindow, from: nil)
        if let pressedAt, hypot(pressedAt.x - point.x, pressedAt.y - point.y) > 3 { return }
        var metrics = ghostty_surface_grid_metrics_s()
        guard ghostty_surface_grid_metrics(surface, &metrics), metrics.cell_width > 0, metrics.cell_height > 0 else { return }
        let top = isFlipped ? point.y : bounds.height - point.y
        let column = Int((point.x - metrics.padding_left) / metrics.cell_width)
        let row = Int((top - metrics.padding_top) / metrics.cell_height)
        guard column >= 0, column < Int(metrics.columns), row >= 0, row < Int(metrics.rows) else { return }
        let selection = ghostty_selection_s(
            top_left: ghostty_point_s(tag: GHOSTTY_POINT_VIEWPORT, coord: GHOSTTY_POINT_COORD_EXACT, x: 0, y: UInt32(row)),
            bottom_right: ghostty_point_s(tag: GHOSTTY_POINT_VIEWPORT, coord: GHOSTTY_POINT_COORD_EXACT,
                                          x: UInt32(metrics.columns) - 1, y: UInt32(row)),
            rectangle: false
        )
        var text = ghostty_text_s()
        guard ghostty_surface_read_text(surface, selection, &text) else { return }
        let line = String(cString: text.text)
        ghostty_surface_free_text(surface, &text)
        guard let url = PreviewLink.url(inLine: line, column: column), PreviewLink.isLocal(url) else { return }
        TerminalLinkRouter.open(url, from: self)
    }
}

/// "localhost:5173 is up — Preview": a card when a dev server starts in the
/// workspace in front, once per port per session, after T3 Code's
/// discovered-server prompt. Servers already up when Octet starts aren't
/// announced; neither are ports seen before, so a restarting server is quiet.
@MainActor
final class DevServerAnnouncer {
    static let shared = DevServerAnnouncer()
    private var seen: Set<Int> = []
    private var announced: Set<Int> = []
    private var baselined = false
    private var watch: AnyCancellable?

    func start() {
        guard watch == nil else { return }
        watch = PortsWatcher.shared.$byPane
            .dropFirst()
            .receive(on: DispatchQueue.main)
            .sink { [weak self] byPane in MainActor.assumeIsolated { self?.update(byPane) } }
        #if DEBUG
        // "browser-server-card" (or ":<port>") shows the card for a sample
        // server without one running.
        if let open = ProcessInfo.processInfo.environment["OCTET_OPEN_WINDOW"], open.hasPrefix("browser-server-card") {
            let port = Int(open.split(separator: ":").dropFirst().first ?? "") ?? 5173
            DispatchQueue.main.asyncAfter(deadline: .now() + 3) { [weak self] in
                guard let ui = WindowRegistry.shared.key?.ui else { return }
                self?.announce(port: port, service: "vite", ui: ui)
            }
        }
        #endif
    }

    private func update(_ byPane: [String: [Int]]) {
        let current = Set(byPane.values.flatMap { $0 })
        // The first reading is what was already running: never announced.
        guard baselined else {
            baselined = true
            seen = current
            return
        }
        let fresh = current.subtracting(seen)
        seen.formUnion(current)
        guard SettingsStore.shared.values.offerServerPreviews, !fresh.isEmpty else { return }
        for window in WindowRegistry.shared.windows where !window.closing {
            guard let workspace = window.focusedWorkspace?.workspaceId else { continue }
            let here = Set(PortsWatcher.shared.ports(inWorkspace: workspace, snapshot: window.store.snapshot))
            // The Browser plane in front already lists what's serving.
            guard !window.ui.showing(.browser) else { continue }
            for port in fresh.intersection(here).sorted() where !announced.contains(port) {
                announce(port: port, service: PortsWatcher.shared.services[port], ui: window.ui)
            }
        }
    }

    private func announce(port: Int, service: String?, ui: UIState) {
        guard announced.insert(port).inserted, let url = URL(string: "http://localhost:\(port)") else { return }
        let name = PreviewServiceName.display(service)
        ToastCenter.shared.info("localhost:\(port) is up",
                                detail: name.map { "\($0) is serving. Open it beside the terminal." }
                                    ?? "Open it beside the terminal.",
                                after: 12,
                                action: .init(title: "Preview") { [weak ui] in ui?.openInBrowserPlane(url) })
        DebugSnapshot.overlay("browser-server-card", true)
        DispatchQueue.main.asyncAfter(deadline: .now() + 12) { DebugSnapshot.overlay("browser-server-card", false) }
    }
}

/// Whether something accepts connections at a host and port, without
/// asking it anything: how the Browser plane knows a server it's waiting on
/// is back.
enum TCPProbe {
    nonisolated static func canConnect(host: String, port: Int, timeout: TimeInterval = 1) -> Bool {
        var hints = addrinfo()
        hints.ai_family = AF_UNSPEC
        hints.ai_socktype = SOCK_STREAM
        var info: UnsafeMutablePointer<addrinfo>?
        let target = host.hasPrefix("[") ? String(host.dropFirst().dropLast()) : host
        guard getaddrinfo(target, String(port), &hints, &info) == 0 else { return false }
        defer { freeaddrinfo(info) }
        var cursor = info
        while let address = cursor {
            if connect(address.pointee, timeout: timeout) { return true }
            cursor = address.pointee.ai_next
        }
        return false
    }

    nonisolated private static func connect(_ address: addrinfo, timeout: TimeInterval) -> Bool {
        let fd = socket(address.ai_family, address.ai_socktype, address.ai_protocol)
        guard fd >= 0 else { return false }
        defer { close(fd) }
        var noSignal: Int32 = 1
        setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &noSignal, socklen_t(MemoryLayout<Int32>.size))
        let flags = fcntl(fd, F_GETFL, 0)
        _ = fcntl(fd, F_SETFL, flags | O_NONBLOCK)
        if Darwin.connect(fd, address.ai_addr, address.ai_addrlen) == 0 { return true }
        guard errno == EINPROGRESS else { return false }
        var poller = pollfd(fd: fd, events: Int16(POLLOUT), revents: 0)
        guard poll(&poller, 1, Int32(timeout * 1000)) > 0 else { return false }
        var error: Int32 = 0
        var length = socklen_t(MemoryLayout<Int32>.size)
        getsockopt(fd, SOL_SOCKET, SO_ERROR, &error, &length)
        return error == 0
    }
}
