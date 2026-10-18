import AppKit
import SwiftUI

// The Browser plane's states beside the page, after T3 Code's preview
// surface: the empty state's server and recent cards (PreviewEmptyState,
// PreviewLocalServerCard, PreviewRecentUrlCard), the unreachable page
// (PreviewUnreachable), the zoom pill (ZoomIndicator) and site icons
// (PreviewFaviconIcon).

// MARK: - Site icons

/// Site icons by origin, fetched once: the page's `<link rel="icon">`, else
/// `/favicon.ico`. An origin with none is asked again after a while, as a
/// dev server may simply not have been up yet.
@MainActor
final class BrowserFavicons: ObservableObject {
    static let shared = BrowserFavicons()
    @Published private(set) var icons: [String: NSImage] = [:]
    private var loading: Set<String> = []
    private var missedAt: [String: Date] = [:]
    /// Icons a loaded page named, ahead of fetching the page for them.
    private var hints: [String: URL] = [:]
    private let session: URLSession = {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = 4
        configuration.timeoutIntervalForResource = 6
        configuration.urlCache = nil
        return URLSession(configuration: configuration)
    }()

    func icon(for url: URL) -> NSImage? {
        PreviewFavicon.cacheKey(for: url).flatMap { icons[$0] }
    }

    /// What a loaded page says its icon is; a different one than cached is
    /// fetched again.
    func hint(_ icon: URL, for page: URL) {
        guard let key = PreviewFavicon.cacheKey(for: page), hints[key] != icon else { return }
        hints[key] = icon
        missedAt[key] = nil
        Task { await load(page, force: true) }
    }

    func load(_ page: URL, force: Bool = false) async {
        guard let key = PreviewFavicon.cacheKey(for: page), !loading.contains(key) else { return }
        if !force {
            if icons[key] != nil { return }
            if let missed = missedAt[key], Date().timeIntervalSince(missed) < 30 { return }
        }
        loading.insert(key)
        defer { loading.remove(key) }
        var candidates: [URL] = []
        if let hinted = hints[key] { candidates.append(hinted) }
        if let named = await iconNamed(by: page) { candidates.append(named) }
        if let fallback = PreviewFavicon.fallbackURL(for: page) { candidates.append(fallback) }
        for candidate in candidates {
            if let image = await image(at: candidate) {
                icons[key] = image
                missedAt[key] = nil
                return
            }
        }
        missedAt[key] = Date()
    }

    private func iconNamed(by page: URL) async -> URL? {
        var request = URLRequest(url: page)
        request.setValue("text/html", forHTTPHeaderField: "Accept")
        guard let (data, response) = try? await session.data(for: request),
              (response as? HTTPURLResponse)?.mimeType?.contains("html") ?? false else { return nil }
        let html = String(decoding: data.prefix(256 * 1024), as: UTF8.self)
        return PreviewFavicon.iconURL(inHTML: html, page: response.url ?? page)
    }

    private func image(at url: URL) async -> NSImage? {
        guard let (data, response) = try? await session.data(from: url),
              (response as? HTTPURLResponse).map({ (200..<300).contains($0.statusCode) }) ?? true,
              !data.isEmpty, let image = NSImage(data: data), image.size.width > 0 else { return nil }
        return image
    }
}

/// A site's icon, or a quiet stand-in: the server's logo, else a globe.
struct BrowserFaviconView: View {
    let url: URL
    var service: String?
    var size: CGFloat = 20
    @ObservedObject private var favicons = BrowserFavicons.shared

    var body: some View {
        Group {
            if let image = favicons.icon(for: url) {
                Image(nsImage: image).resizable().interpolation(.high).aspectRatio(contentMode: .fit)
                    .frame(width: size, height: size)
                    .clipShape(RoundedRectangle(cornerRadius: 4))
            } else if let logo = LanguageLogo(service: service, size: size * 0.8) {
                logo
            } else {
                OctetIcon("safari", size: size * 0.8).foregroundStyle(Theme.textTertiary)
            }
        }
        .frame(width: size + 8, height: size + 8)
        .background(RoundedRectangle(cornerRadius: Theme.controlRadius).fill(Theme.card))
        .overlay(RoundedRectangle(cornerRadius: Theme.controlRadius).strokeBorder(Theme.border, lineWidth: 1))
        .task(id: url) { await favicons.load(url) }
    }
}

// MARK: - Recents

/// The recents store, observable: the Browser plane's "Recent" list.
@MainActor
final class BrowserRecents: ObservableObject {
    static let shared = BrowserRecents()
    private let store = PreviewRecentsStore()
    /// Sample entries shown instead, for the verification hook.
    private var samples: [PreviewRecent]?

    func entries(for folder: String) -> [PreviewRecent] {
        samples ?? store.entries(for: folder)
    }

    func record(_ url: URL, title: String?, folder: String) {
        store.record(url, title: title, folder: folder)
        objectWillChange.send()
    }

    func remove(_ address: String, folder: String) {
        if samples != nil { samples?.removeAll { $0.url == address } } else { store.remove(address, folder: folder) }
        objectWillChange.send()
    }

    #if DEBUG
    func showSamples(for folder: String, ports: [Int]) {
        let now = Date()
        var list: [PreviewRecent] = ports.enumerated().map { index, port in
            PreviewRecent(url: "http://localhost:\(port)/", title: nil, visitedAt: now.addingTimeInterval(Double(-index - 1) * 600))
        }
        list += [
            PreviewRecent(url: "http://localhost:5173/settings/profile", title: "Profile · Settings", visitedAt: now.addingTimeInterval(-3_600)),
            PreviewRecent(url: "http://127.0.0.1:8000/docs", title: "FastAPI - Swagger UI", visitedAt: now.addingTimeInterval(-86_400)),
            PreviewRecent(url: "http://mailpit.lan:8025/", title: "Mailpit", visitedAt: now.addingTimeInterval(-3 * 86_400)),
        ]
        samples = list
        objectWillChange.send()
    }
    #endif
}

// MARK: - Empty state

/// No page yet: recent pages and what's serving, as cards, after T3 Code's
/// "No preview yet".
struct BrowserEmptyState: View {
    let servers: [Int]
    let services: [Int: String]
    let recents: [PreviewRecent]
    let open: (URL) -> Void
    let removeRecent: (String) -> Void

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 22) {
                if servers.isEmpty && recents.isEmpty {
                    nothingYet
                } else {
                    if !servers.isEmpty {
                        section("Local servers", icon: "antenna.radiowaves.left.and.right") {
                            ForEach(servers, id: \.self) { port in
                                let url = URL(string: "http://localhost:\(port)")!
                                BrowserCard(url: url, service: services[port],
                                            title: PreviewServiceName.display(services[port]) ?? "Listening",
                                            subtitle: "localhost:\(String(port))") { open(url) }
                            }
                        }
                        Text("Pick a server to open it here.")
                            .font(Theme.captionFont)
                            .foregroundStyle(Theme.textTertiary)
                            .padding(.top, -14)
                            .padding(.leading, 2)
                    }
                    if !recents.isEmpty {
                        section("Recent", icon: "clock") {
                            ForEach(recents.prefix(8)) { entry in
                                if let url = URL(string: entry.url) {
                                    BrowserCard(url: url, service: nil,
                                                title: entry.title ?? Self.label(url),
                                                subtitle: (entry.title == nil ? "" : Self.label(url) + " · ")
                                                    + Self.ago(entry.visitedAt),
                                                remove: { removeRecent(entry.url) }) { open(url) }
                                }
                            }
                        }
                    }
                }
            }
            .frame(maxWidth: 440, alignment: .leading)
            .padding(.horizontal, 20)
            .padding(.vertical, 28)
            .frame(maxWidth: .infinity)
        }
        .scrollIndicators(.never)
        .background(Theme.sidebar)
    }

    private var nothingYet: some View {
        VStack(spacing: 8) {
            OctetIcon("safari", size: 20)
                .foregroundStyle(Theme.textTertiary)
                .frame(width: 36, height: 36)
                .background(RoundedRectangle(cornerRadius: Theme.controlRadius).fill(Theme.card))
            Text("No preview yet")
                .font(.system(size: 14, weight: .medium))
                .foregroundStyle(Theme.textPrimary)
            Text("Type an address above, or start a dev server. Local servers show up here as they start.")
                .font(Theme.captionFont)
                .foregroundStyle(Theme.textTertiary)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 260)
        }
        .frame(maxWidth: .infinity)
        .padding(.top, 60)
    }

    private func section<Content: View>(_ title: String, icon: String, @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 6) {
                OctetIcon(icon, size: 12)
                Text(title).font(Theme.uiFontMedium)
            }
            .foregroundStyle(Theme.textSecondary)
            .padding(.leading, 2)
            VStack(spacing: 0) { content() }
                .background(RoundedRectangle(cornerRadius: Theme.popoverRadius).fill(Theme.card.opacity(0.6)))
                .overlay(RoundedRectangle(cornerRadius: Theme.popoverRadius).strokeBorder(Theme.border, lineWidth: 1))
                .clipShape(RoundedRectangle(cornerRadius: Theme.popoverRadius))
        }
    }

    /// host, path and query, as T3 Code labels a recent page.
    static func label(_ url: URL) -> String {
        let host = url.host(percentEncoded: false).map { h in url.port.map { "\(h):\($0)" } ?? h } ?? url.absoluteString
        let path = url.path(percentEncoded: false)
        return host + (path == "/" ? "" : path) + (url.query().map { "?" + $0 } ?? "")
    }

    static func ago(_ date: Date) -> String {
        let seconds = Date().timeIntervalSince(date)
        if seconds < 60 { return "just now" }
        let formatter = RelativeDateTimeFormatter()
        formatter.unitsStyle = .full
        return formatter.localizedString(for: date, relativeTo: Date())
    }
}

/// One server or page in the empty state: its icon, a name and where it is.
private struct BrowserCard: View {
    let url: URL
    let service: String?
    let title: String
    let subtitle: String
    var remove: (() -> Void)?
    let open: () -> Void
    @State private var hovered = false

    var body: some View {
        Button(action: open) {
            HStack(spacing: 10) {
                BrowserFaviconView(url: url, service: service, size: 16)
                VStack(alignment: .leading, spacing: 1) {
                    Text(title)
                        .font(Theme.uiFontMedium)
                        .foregroundStyle(Theme.textPrimary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                    Text(subtitle)
                        .font(Theme.captionFont)
                        .foregroundStyle(Theme.textTertiary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                }
                Spacer(minLength: 0)
                if remove != nil { Color.clear.frame(width: 22, height: 22) }
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 8)
            .background(hovered ? Theme.hover : .clear)
            .contentShape(Rectangle())
        }
        .buttonStyle(OctetPressStyle())
        .overlay(alignment: .trailing) {
            if let remove, hovered {
                OctetIconButton(icon: "xmark", help: "Remove from Recent", compact: true, action: remove)
                    .padding(.trailing, 8)
            }
        }
        .onHover { hovered = $0 }
        .help(url.absoluteString)
    }
}

// MARK: - Unreachable

/// A page that didn't load, in the plane rather than a toast, after T3
/// Code's "This site can't be reached". A local server that may be starting
/// is waited for, and the page loads by itself once it answers.
struct BrowserUnreachable: View {
    let failure: BrowserPage.Failure
    let waiting: Bool
    let retry: () -> Void
    let openOutside: () -> Void
    @State private var details = false

    var body: some View {
        let host = failure.url.host(percentEncoded: false).map { h in failure.url.port.map { "\(h):\($0)" } ?? h }
            ?? failure.url.absoluteString
        ScrollView {
            VStack(alignment: .leading, spacing: 0) {
                OctetIcon("wifi.exclamationmark", size: 30)
                    .foregroundStyle(Theme.textTertiary)
                    .padding(.bottom, 16)
                Text("This site can't be reached")
                    .font(.system(size: 17, weight: .semibold))
                    .foregroundStyle(Theme.textPrimary)
                    .padding(.bottom, 8)
                (Text(host).foregroundColor(Theme.textPrimary).fontWeight(.semibold)
                    + Text(" \(PreviewLoadError.reason(code: failure.code, fallback: failure.message)).")
                    .foregroundColor(Theme.textSecondary))
                    .font(Theme.uiFont)
                    .fixedSize(horizontal: false, vertical: true)
                Text(failure.url.absoluteString)
                    .font(Theme.monoFont)
                    .foregroundStyle(Theme.textTertiary)
                    .lineLimit(2)
                    .truncationMode(.middle)
                    .textSelection(.enabled)
                    .padding(.top, 10)
                if waiting {
                    HStack(spacing: 8) {
                        LoadingLine(width: 18)
                        Text("Waiting for the server… it opens here once it's up.")
                            .font(Theme.captionFont)
                            .foregroundStyle(Theme.textSecondary)
                    }
                    .padding(.top, 16)
                }
                if details {
                    VStack(alignment: .leading, spacing: 4) {
                        Text("Try:").font(Theme.uiFontMedium).foregroundStyle(Theme.textPrimary)
                        ForEach(tips, id: \.self) { tip in
                            Text("•  " + tip).font(Theme.captionFont).foregroundStyle(Theme.textSecondary)
                        }
                    }
                    .padding(12)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(RoundedRectangle(cornerRadius: Theme.controlRadius).fill(Theme.card))
                    .overlay(RoundedRectangle(cornerRadius: Theme.controlRadius).strokeBorder(Theme.border, lineWidth: 1))
                    .padding(.top, 16)
                }
                Text(PreviewLoadError.label(code: failure.code))
                    .font(Theme.headerFont)
                    .tracking(0.6)
                    .foregroundStyle(Theme.textMuted)
                    .padding(.top, 22)
                HStack(spacing: 8) {
                    OctetButton(title: details ? "Hide Details" : "Details", kind: .ghost, compact: true) { details.toggle() }
                    Spacer(minLength: 0)
                    OctetButton(title: "Open in Browser", compact: true, action: openOutside)
                    OctetButton(title: "Retry", kind: .primary, compact: true, action: retry)
                        .keyboardShortcut("r", modifiers: .command)
                }
                .padding(.top, 24)
            }
            .frame(maxWidth: 440, alignment: .leading)
            .padding(.horizontal, 24)
            .padding(.vertical, 40)
            .frame(maxWidth: .infinity)
        }
        .scrollIndicators(.never)
        .background(Theme.sidebar)
        .onAppear { DebugSnapshot.overlay("browser-unreachable", true) }
        .onDisappear { DebugSnapshot.overlay("browser-unreachable", false) }
    }

    private var tips: [String] {
        var tips = ["Checking the dev server is running in a terminal", "Checking the port and address"]
        if PreviewLink.isLocal(failure.url) {
            tips.append("Binding the server to localhost or 0.0.0.0")
        } else {
            tips.append("Checking your connection, proxy and firewall")
        }
        return tips
    }
}

// MARK: - Zoom pill

/// The page's zoom for a moment after it changes, after T3 Code's
/// ZoomIndicator.
struct BrowserZoomIndicator: View {
    let zoom: Double
    @State private var visible = false
    @State private var hide: DispatchWorkItem?
    @ObservedObject private var motion = MotionPreferences.shared

    var body: some View {
        Text(PreviewZoom.label(zoom))
            .font(Theme.uiFontMedium)
            .monospacedDigit()
            .foregroundStyle(Theme.textPrimary)
            .fixedSize()
            .padding(.horizontal, 10)
            .frame(height: 24)
            .background(Capsule().fill(Theme.chrome.opacity(0.96)))
            .overlay(Capsule().strokeBorder(Theme.border, lineWidth: 1))
            .shadow(color: .black.opacity(0.12), radius: 4, y: 1)
            .opacity(visible ? 1 : 0)
            .offset(y: visible ? 0 : -4)
            .animation(motion.animation(.toasts, .easeOut(duration: 0.18)), value: visible)
            .allowsHitTesting(false)
            .accessibilityHidden(!visible)
            .onChange(of: zoom) { _, _ in show() }
    }

    private func show() {
        visible = true
        DebugSnapshot.overlay("browser-zoom", true)
        hide?.cancel()
        let work = DispatchWorkItem {
            visible = false
            DebugSnapshot.overlay("browser-zoom", false)
        }
        hide = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.5, execute: work)
    }
}
