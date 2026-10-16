import SwiftUI
import WebKit

/// The Browser plane: a page beside the terminal, after T3 Code's browser
/// surface, mostly for the dev server an agent is working on. With nothing
/// open it lists what's serving on localhost, from the ports Octet watches.
struct BrowserPlane: View {
    @ObservedObject var ui: UIState
    @StateObject private var page = BrowserPage()
    @ObservedObject private var ports = PortsWatcher.shared
    @State private var address = ""
    @FocusState private var addressFocused: Bool

    var body: some View {
        VStack(spacing: 0) {
            toolbar
            Rectangle().fill(Theme.divider).frame(height: 1)
            ZStack {
                BrowserWebView(page: page)
                    .opacity(page.url == nil ? 0 : 1)
                if page.url == nil { start }
            }
            .overlay(alignment: .top) {
                if page.loading { LoadingLine(width: 60).padding(.top, 2) }
            }
        }
        .onChange(of: page.url) { _, url in
            if !addressFocused { address = url?.absoluteString ?? "" }
            if let url { ui.planeBadges[Plane.make(.browser).id] = PlaneBadge(title: url.host() ?? "Browser", help: url.absoluteString) }
        }
    }

    private var toolbar: some View {
        HStack(spacing: 4) {
            OctetIconButton(icon: "arrow.left", help: "Back") { page.view.goBack() }
                .disabled(!page.canGoBack)
            OctetIconButton(icon: "arrow.right", help: "Forward") { page.view.goForward() }
                .disabled(!page.canGoForward)
            OctetIconButton(icon: "arrow.clockwise", help: "Reload") { page.view.reload() }
                .disabled(page.url == nil)
            HStack(spacing: 6) {
                OctetIcon(page.url?.scheme == "https" ? "lock" : "safari", size: 11)
                    .foregroundStyle(Theme.textTertiary)
                TextField("Search or enter an address", text: $address)
                    .textFieldStyle(.plain)
                    .font(Theme.uiFont)
                    .focused($addressFocused)
                    .onSubmit { go(address) }
                    .onExitCommand {
                        address = page.url?.absoluteString ?? ""
                        addressFocused = false
                    }
            }
            .padding(.horizontal, 8)
            .frame(height: 26)
            .background(RoundedRectangle(cornerRadius: Theme.controlRadius)
                .fill(addressFocused ? Theme.cardSelected : Theme.card.opacity(0.7)))
            OctetIconButton(icon: "arrow.up.right", help: "Open in your browser") {
                if let url = page.url { NSWorkspace.shared.open(url) }
            }
            .disabled(page.url == nil)
        }
        .padding(.horizontal, 8)
        .frame(height: 38)
    }

    /// No page yet: what's serving here, after T3 Code's "No preview yet".
    private var start: some View {
        let serving = Array(Set(ports.byPane.values.flatMap { $0 })).sorted()
        return VStack(alignment: .leading, spacing: 10) {
            Text("No preview yet")
                .font(.system(size: 14, weight: .medium))
                .foregroundStyle(Theme.textPrimary)
            Text("Open a page, or one of the servers running in your terminals.")
                .font(Theme.captionFont)
                .foregroundStyle(Theme.textTertiary)
            if !serving.isEmpty {
                Text("Local servers")
                    .font(Theme.uiFontMedium)
                    .foregroundStyle(Theme.textSecondary)
                    .padding(.top, 6)
                VStack(spacing: 1) {
                    ForEach(serving, id: \.self) { port in
                        BrowserServerRow(port: port, service: ports.services[port]) { go("http://localhost:\(port)") }
                    }
                }
            }
        }
        .frame(maxWidth: 320, alignment: .leading)
        .padding(24)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Theme.sidebar)
    }

    private func go(_ text: String) {
        guard let url = BrowserAddress.url(from: text) else { return }
        addressFocused = false
        page.view.load(URLRequest(url: url))
    }
}

private struct BrowserServerRow: View {
    let port: Int
    let service: String?
    let open: () -> Void
    @State private var hovered = false

    var body: some View {
        Button(action: open) {
            HStack(spacing: 10) {
                if let logo = LanguageLogo(service: service, size: 14) {
                    logo.frame(width: 18)
                } else {
                    OctetIcon("safari", size: 14).foregroundStyle(Theme.textTertiary).frame(width: 18)
                }
                Text("localhost:\(String(port))")
                    .font(Theme.monoFont)
                    .foregroundStyle(Theme.textPrimary)
                if let service {
                    Text(service).font(Theme.captionFont).foregroundStyle(Theme.textTertiary).lineLimit(1)
                }
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 10)
            .frame(height: 32)
            .background(RoundedRectangle(cornerRadius: Theme.controlRadius).fill(hovered ? Theme.hover : .clear))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hovered = $0 }
    }
}

/// The page's web view and what the toolbar shows about it.
@MainActor
final class BrowserPage: NSObject, ObservableObject, WKNavigationDelegate {
    let view: WKWebView
    @Published private(set) var url: URL?
    @Published private(set) var loading = false
    @Published private(set) var canGoBack = false
    @Published private(set) var canGoForward = false

    override init() {
        let configuration = WKWebViewConfiguration()
        configuration.preferences.isElementFullscreenEnabled = true
        view = WKWebView(frame: .zero, configuration: configuration)
        view.allowsBackForwardNavigationGestures = true
        view.allowsMagnification = true
        #if DEBUG
        view.isInspectable = true
        #endif
        super.init()
        view.navigationDelegate = self
    }

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
        MainActor.assumeIsolated { update() }
    }

    nonisolated func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        MainActor.assumeIsolated { update() }
    }

    nonisolated func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) {
        MainActor.assumeIsolated { update() }
    }

    nonisolated func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) {
        MainActor.assumeIsolated {
            update()
            let code = (error as NSError).code
            guard code != NSURLErrorCancelled else { return }
            ToastCenter.shared.fail(nil, "Couldn't open the page", detail: error.localizedDescription)
        }
    }
}

private struct BrowserWebView: NSViewRepresentable {
    let page: BrowserPage
    func makeNSView(context: Context) -> WKWebView { page.view }
    func updateNSView(_ nsView: WKWebView, context: Context) {}
}
