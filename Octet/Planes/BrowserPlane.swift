import SwiftUI
import WebKit

/// The Browser plane: a page beside the terminal, after T3 Code's preview
/// surface, mostly for the dev server an agent is working on. With nothing
/// open it shows what's serving on localhost and the pages visited lately;
/// a page that won't load says why in the plane and, for a local server
/// that's starting, waits for it.
struct BrowserPlane: View {
    @ObservedObject var ui: UIState
    /// The project folder in front, whose recent pages are listed.
    var directory: String?
    @StateObject private var page = BrowserPage(private: false)
    /// T3 Code's browser profiles, as Safari's: a private page keeps no
    /// cookies, storage or history once the plane closes.
    @StateObject private var privatePage = BrowserPage(private: true)
    @State private var isPrivate = false

    private var current: BrowserPage { isPrivate ? privatePage : page }
    @ObservedObject private var ports = PortsWatcher.shared
    @ObservedObject private var recents = BrowserRecents.shared
    @State private var address = ""
    @FocusState private var addressFocused: Bool

    /// Recents are kept per project: the repository's root, else the folder.
    private var folder: String {
        directory.map { AccountProfiles.projectRoot(of: $0) ?? $0 } ?? ""
    }

    private var serving: [Int] { Array(Set(ports.byPane.values.flatMap { $0 })).sorted() }

    var body: some View {
        VStack(spacing: 0) {
            toolbar
            Rectangle().fill(Theme.divider).frame(height: 1)
            ZStack {
                BrowserWebView(page: current)
                    .id(isPrivate)
                    .opacity(current.showingStart || current.failure != nil ? 0 : 1)
                if PlaneLoadingPreview.shows("browser") || (current.loading && !current.hasContent && current.failure == nil) {
                    BrowserPlaneSkeleton().allowsHitTesting(false)
                } else if let failure = current.failure {
                    BrowserUnreachable(failure: failure, waiting: current.waiting,
                                       retry: { current.reload() },
                                       openOutside: { NSWorkspace.shared.open(failure.url) })
                } else if current.showingStart {
                    BrowserEmptyState(servers: serving, services: ports.services,
                                      recents: isPrivate ? [] : recents.entries(for: folder),
                                      open: { current.load($0) },
                                      removeRecent: { recents.remove($0, folder: folder) })
                }
            }
            .overlay(alignment: .top) {
                if current.loading || PlaneLoadingPreview.shows("browser") { LoadingLine(width: 60).padding(.top, 2) }
            }
            .overlay(alignment: .topTrailing) {
                BrowserZoomIndicator(zoom: current.zoom).id(isPrivate).padding(10)
            }
        }
        // A plane opened for a request finds it on appearing; one already
        // open hears it change.
        .onAppear {
            takeRequest()
            runDebugHook()
        }
        .onChange(of: ui.browserRequest) { _, _ in takeRequest() }
        .onChange(of: current.url) { _, url in
            if !addressFocused { address = current.pageURL?.absoluteString ?? "" }
            if let url, !current.showingStart { ui.planeBadges[Plane.make(.browser).id] = PlaneBadge(title: url.host() ?? "Browser", help: url.absoluteString) }
        }
        .onChange(of: current.failure) { _, failure in
            if let failure, !addressFocused { address = failure.url.absoluteString }
        }
        // The private profile keeps no history, Recent included.
        .onChange(of: page.lastVisit) { _, visit in
            if let visit { recents.record(visit.url, title: visit.title, folder: folder) }
        }
        // A server being waited on that Octet now sees listening: try now
        // rather than at the next probe.
        .onChange(of: serving) { _, serving in
            if let port = current.failure.flatMap({ PreviewLink.port(of: $0.url) }), serving.contains(port) {
                current.retryWhenUp()
            }
        }
    }

    private var toolbar: some View {
        HStack(spacing: 4) {
            OctetIconButton(icon: "arrow.left", help: "Back") { current.view.goBack() }
                .disabled(!current.canGoBack)
            OctetIconButton(icon: "arrow.right", help: "Forward") { current.view.goForward() }
                .disabled(!current.canGoForward)
            OctetIconButton(icon: "arrow.clockwise", help: "Reload") { current.reload() }
                .disabled(current.pageURL == nil)
            HStack(spacing: 6) {
                OctetIcon(current.url?.scheme == "https" ? "lock" : "safari", size: 11)
                    .foregroundStyle(Theme.textTertiary)
                TextField("Search or enter an address", text: $address)
                    .textFieldStyle(.plain)
                    .font(Theme.uiFont)
                    .focused($addressFocused)
                    .onSubmit { go(address) }
                    .onExitCommand {
                        address = current.pageURL?.absoluteString ?? ""
                        addressFocused = false
                    }
            }
            .padding(.horizontal, 8)
            .frame(height: 26)
            .background(RoundedRectangle(cornerRadius: Theme.controlRadius)
                .fill(addressFocused ? Theme.cardSelected : Theme.card.opacity(0.7)))
            OctetIconButton(icon: isPrivate ? "eye.slash" : "eye",
                            help: isPrivate ? "Private: nothing is kept. Switch to the default profile" : "Switch to a private page",
                            active: isPrivate) {
                isPrivate.toggle()
                address = current.pageURL?.absoluteString ?? ""
            }
            OctetIconButton(icon: "arrow.up.right", help: "Open in your browser") {
                if let url = current.pageURL { NSWorkspace.shared.open(url) }
            }
            .disabled(current.pageURL == nil)
            OctetIconButton(icon: "ellipsis", help: "More") { showMoreMenu() }
        }
        .padding(.horizontal, 8)
        .frame(height: 38)
    }

    /// After T3 Code's PreviewMoreMenu.
    private func moreMenuItems() -> [OctetMenuItem] {
        let page = current
        let url = page.pageURL
        var items: [OctetMenuItem] = [
            .action("Reload", icon: "arrow.clockwise", shortcut: "⌘R", enabled: url != nil) { page.reload() },
            .action("Hard Reload", icon: "arrow.clockwise", shortcut: "⇧⌘R",
                    enabled: url != nil, help: "Reload without the cache") { page.hardReload() },
            .divider,
            .action("Copy URL", icon: "doc.on.doc", enabled: url != nil) {
                guard let url else { return }
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(url.absoluteString, forType: .string)
            },
            .action("Open in Browser", icon: "arrow.up.right", enabled: url != nil) {
                if let url { NSWorkspace.shared.open(url) }
            },
            .action("Start Page", icon: "safari", enabled: url != nil,
                    help: "Local servers and recent pages") { page.showStart() },
            .divider,
            .header("Zoom  \(PreviewZoom.label(page.zoom))"),
            .action("Zoom In", icon: "plus", shortcut: "⌘+", enabled: page.zoom < PreviewZoom.steps.last!) { page.zoomIn() },
            .action("Zoom Out", icon: "minus", shortcut: "⌘−", enabled: page.zoom > PreviewZoom.steps.first!) { page.zoomOut() },
            .action("Reset Zoom", icon: "arrow.counterclockwise.circle", shortcut: "⌘0",
                    enabled: abs(page.zoom - 1) > 0.001) { page.setZoom(1) },
            .divider,
        ]
        if BrowserPage.inspectorAvailable {
            items.append(.action("Web Inspector", icon: "wrench.and.screwdriver", shortcut: "⌥⌘I",
                                 enabled: url != nil && page.failure == nil) { page.showInspector() })
        }
        items.append(.action("Clear Private Site Data", icon: "trash", destructive: true,
                             help: "Cookies, storage and cache of the private page") {
            privatePage.clearSiteData()
        })
        return items
    }

    private func showMoreMenu(at location: NSPoint = NSEvent.mouseLocation) {
        OctetContextMenu.present(moreMenuItems(), at: location)
    }

    private func takeRequest() {
        guard let request = ui.browserRequest else { return }
        ui.browserRequest = nil
        go(request.url.absoluteString)
    }

    private func go(_ text: String) {
        guard let url = BrowserAddress.url(from: text) else { return }
        addressFocused = false
        current.load(url)
    }

    /// Verification hooks, after "planes:browser" opened the plane:
    /// "planes:browser:unreachable[:port]" loads a port nothing listens on,
    /// "planes:browser:recents" fills Recent with samples,
    /// "planes:browser:menu" opens the ⋯ menu, "planes:browser:zoom" zooms
    /// the page, and "planes:browser:open:<url>" loads that address.
    private func runDebugHook() {
        #if DEBUG
        guard !BrowserPage.debugHookRan,
              let open = ProcessInfo.processInfo.environment["OCTET_OPEN_WINDOW"],
              open.hasPrefix("planes:browser:") else { return }
        BrowserPage.debugHookRan = true
        let argument = String(open.dropFirst("planes:browser:".count))
        DispatchQueue.main.asyncAfter(deadline: .now() + 1) {
            if argument.hasPrefix("unreachable") {
                let port = Int(argument.split(separator: ":").dropFirst().first ?? "") ?? 59_999
                go("http://localhost:\(port)")
            } else if argument == "recents" {
                recents.showSamples(for: folder, ports: serving.isEmpty ? [5173, 3000] : serving)
            } else if argument.hasPrefix("open:") {
                go(String(argument.dropFirst(5)))
            } else if argument.hasPrefix("visit:") {
                // Loads a page, then goes back to the start page to show it in Recent.
                go(String(argument.dropFirst(6)))
                DispatchQueue.main.asyncAfter(deadline: .now() + 4) { current.showStart() }
            } else if argument.hasPrefix("zoom") {
                if argument.hasPrefix("zoom:") { go(String(argument.dropFirst(5))) }
                DispatchQueue.main.asyncAfter(deadline: .now() + 2) { current.setZoom(1.25) }
            } else if argument == "menu" {
                // Once the window is on screen, under the ⋯ button.
                DispatchQueue.main.asyncAfter(deadline: .now() + 2) {
                    guard let window = current.view.window ?? NSApp.windows.first(where: { $0.isVisible && $0.contentView != nil })
                    else { return }
                    showMoreMenu(at: NSPoint(x: window.frame.maxX - 230, y: window.frame.maxY - 100))
                }
            }
        }
        #endif
    }
}

/// The page's web view and what the toolbar shows about it.
@MainActor
final class BrowserPage: NSObject, ObservableObject, WKNavigationDelegate {
    /// A load that failed before anything came back.
    struct Failure: Equatable {
        let url: URL
        let code: Int
        let message: String
    }

    struct Visit: Equatable {
        let url: URL
        let title: String?
        let at: Date
    }

    let view: WKWebView
    let isPrivate: Bool
    @Published private(set) var url: URL?
    @Published private(set) var loading = false
    @Published private(set) var hasContent = false
    @Published private(set) var canGoBack = false
    @Published private(set) var canGoForward = false
    @Published private(set) var failure: Failure?
    /// Waiting for a local server to answer, to load the failed page again.
    @Published private(set) var waiting = false
    @Published private(set) var zoom: Double = 1
    /// The last page finished loading, for Recent (never set when private).
    @Published private(set) var lastVisit: Visit?
    private var requested: URL?
    private var keyMonitor: Any?
    private var waitTimer: Timer?
    private var probing = false
    private var titleWatch: NSKeyValueObservation?
    #if DEBUG
    static var debugHookRan = false
    #endif

    /// What the page is, or was trying to be; nil on the start page.
    var pageURL: URL? { failure?.url ?? (showingStart ? nil : url) }

    /// No page: the start page's servers and recent pages show instead.
    var showingStart: Bool { url == nil || url?.scheme == "about" }

    /// Back to the start page, keeping the way back to the page.
    func showStart() {
        failure = nil
        stopWaiting()
        view.loadHTMLString("", baseURL: URL(string: "about:blank"))
    }

    init(private isPrivate: Bool) {
        self.isPrivate = isPrivate
        let configuration = WKWebViewConfiguration()
        if isPrivate { configuration.websiteDataStore = .nonPersistent() }
        configuration.preferences.isElementFullscreenEnabled = true
        view = WKWebView(frame: .zero, configuration: configuration)
        view.allowsBackForwardNavigationGestures = true
        view.allowsMagnification = true
        if Self.inspectorAvailable { view.isInspectable = true }
        super.init()
        view.navigationDelegate = self
        // Pages often name themselves after loading: Recent takes the title then.
        titleWatch = view.observe(\.title, options: [.new]) { [weak self] webView, _ in
            DispatchQueue.main.async {
                MainActor.assumeIsolated {
                    guard let self, !self.isPrivate, let url = webView.url, url.scheme?.hasPrefix("http") == true,
                          let title = webView.title, !title.isEmpty,
                          let visit = self.lastVisit, visit.url == url, visit.title != title else { return }
                    self.lastVisit = Visit(url: url, title: title, at: visit.at)
                }
            }
        }
        keyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            guard let self else { return event }
            return MainActor.assumeIsolated { self.handleKey(event) } ? nil : event
        }
    }

    deinit {
        if let keyMonitor { NSEvent.removeMonitor(keyMonitor) }
        waitTimer?.invalidate()
    }

    /// The Web Inspector: debug builds, or with WebKit's developer extras on
    /// (`defaults write com.jpxsoftware.octet WebKitDeveloperExtras -bool YES`).
    static var inspectorAvailable: Bool {
        #if DEBUG
        return true
        #else
        return UserDefaults.standard.bool(forKey: "WebKitDeveloperExtras")
        #endif
    }

    // MARK: Loading

    /// `retrying` keeps the failure on screen until the page commits, so
    /// trying again doesn't flash the page away and back.
    func load(_ url: URL, retrying: Bool = false) {
        if !retrying { failure = nil }
        stopWaiting()
        requested = url
        view.load(URLRequest(url: url))
    }

    func reload() {
        if let failure { load(failure.url, retrying: true) } else { view.reload() }
    }

    func hardReload() {
        if let failure { load(failure.url, retrying: true) } else { view.reloadFromOrigin() }
    }

    /// Asks once now whether the server being waited on is up.
    func retryWhenUp() {
        guard waiting else { return }
        probe()
    }

    // MARK: Zoom

    func setZoom(_ value: Double) {
        view.pageZoom = value
        zoom = value
    }

    func zoomIn() { setZoom(PreviewZoom.zoomIn(from: zoom)) }
    func zoomOut() { setZoom(PreviewZoom.zoomOut(from: zoom)) }

    /// ⌘+, ⌘− and ⌘0 zoom, ⌘R and ⇧⌘R reload, ⌥⌘I inspects — only while the
    /// page itself has focus, so the terminal's own keys are untouched.
    private func handleKey(_ event: NSEvent) -> Bool {
        guard event.window === view.window, pageHasFocus else { return false }
        let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask).subtracting([.capsLock, .numericPad, .function])
        let key = event.charactersIgnoringModifiers?.lowercased() ?? ""
        switch (flags, key) {
        case (.command, "="), (.command, "+"), ([.command, .shift], "="), ([.command, .shift], "+"): zoomIn()
        case (.command, "-"), ([.command, .shift], "_"): zoomOut()
        case (.command, "0"): setZoom(1)
        case (.command, "r"): reload()
        case ([.command, .shift], "r"): hardReload()
        case ([.command, .option], "i") where Self.inspectorAvailable: showInspector()
        default: return false
        }
        return true
    }

    private var pageHasFocus: Bool {
        guard let responder = view.window?.firstResponder as? NSView else { return false }
        return responder === view || responder.isDescendant(of: view)
    }

    // MARK: Developer and privacy

    func showInspector() {
        let getter = NSSelectorFromString("_inspector")
        guard view.responds(to: getter), let inspector = view.perform(getter)?.takeUnretainedValue() as? NSObject else { return }
        let show = NSSelectorFromString("show")
        if inspector.responds(to: show) { inspector.perform(show) }
    }

    /// Clears what this page's profile keeps: cookies, storage and cache.
    func clearSiteData() {
        let store = view.configuration.websiteDataStore
        store.removeData(ofTypes: WKWebsiteDataStore.allWebsiteDataTypes(), modifiedSince: .distantPast) {
            ToastCenter.shared.succeed(nil, "Cleared private site data")
        }
    }

    // MARK: Waiting for a server

    private func startWaiting() {
        guard let failure, PreviewLink.isLocal(failure.url), PreviewLoadError.serverMayComeBack(code: failure.code) else { return }
        waiting = true
        waitTimer?.invalidate()
        waitTimer = Timer.scheduledTimer(withTimeInterval: 2, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.probe() }
        }
    }

    private func stopWaiting() {
        waiting = false
        waitTimer?.invalidate()
        waitTimer = nil
    }

    private func probe() {
        guard waiting, !probing, let target = failure?.url,
              let host = target.host(percentEncoded: false), let port = PreviewLink.port(of: target) else { return }
        probing = true
        DispatchQueue.global(qos: .utility).async {
            let up = TCPProbe.canConnect(host: host, port: port)
            DispatchQueue.main.async { [weak self] in
                MainActor.assumeIsolated {
                    guard let self else { return }
                    self.probing = false
                    // Loading again is quiet: another failure only keeps waiting.
                    if up, self.waiting, self.failure?.url == target { self.load(target, retrying: true) }
                }
            }
        }
    }

    // MARK: Navigation

    private func update() {
        url = view.url
        loading = view.isLoading
        canGoBack = view.canGoBack
        canGoForward = view.canGoForward
    }

    nonisolated func webView(_ webView: WKWebView, didStartProvisionalNavigation navigation: WKNavigation!) {
        MainActor.assumeIsolated { update() }
    }

    nonisolated func webView(_ webView: WKWebView, didCommit navigation: WKNavigation!) {
        MainActor.assumeIsolated {
            failure = nil
            hasContent = true
            stopWaiting()
            update()
        }
    }

    nonisolated func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        MainActor.assumeIsolated {
            update()
            guard let url = view.url, url.scheme?.hasPrefix("http") == true else { return }
            if !isPrivate { lastVisit = Visit(url: url, title: view.title, at: Date()) }
            // The icon the page names, for its card in the empty state.
            let script = "(() => { const l = document.querySelector('link[rel~=\"icon\"], link[rel=\"apple-touch-icon\"]'); return l ? l.href : null })()"
            view.evaluateJavaScript(script) { result, _ in
                MainActor.assumeIsolated {
                    if let href = result as? String, let icon = URL(string: href) { BrowserFavicons.shared.hint(icon, for: url) }
                }
            }
        }
    }

    nonisolated func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) {
        MainActor.assumeIsolated { update() }
    }

    nonisolated func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) {
        MainActor.assumeIsolated {
            update()
            let error = error as NSError
            if error.domain == NSURLErrorDomain && error.code == NSURLErrorCancelled { return }
            // A response turned into a download, or one WebKit hands off.
            if error.domain == "WebKitErrorDomain" && (error.code == 102 || error.code == 204) { return }
            let failing = (error.userInfo[NSURLErrorFailingURLErrorKey] as? URL)
                ?? (error.userInfo[NSURLErrorFailingURLStringErrorKey] as? String).flatMap(URL.init(string:))
                ?? requested
            guard let failing else { return }
            let failed = Failure(url: failing, code: error.code, message: error.localizedDescription)
            if failure != failed { failure = failed }
            if !waiting { startWaiting() }
        }
    }
}

private struct BrowserWebView: NSViewRepresentable {
    let page: BrowserPage
    func makeNSView(context: Context) -> WKWebView { page.view }
    func updateNSView(_ nsView: WKWebView, context: Context) {}
}
