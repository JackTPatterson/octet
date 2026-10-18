import Foundation

/// Which addresses the Browser plane takes over from the system browser:
/// dev servers on this Mac or the local network, after T3 Code's
/// `openTerminalLinkInPreview`. Everything else keeps opening as it did.
enum PreviewLink {
    /// An http(s) address on this Mac or the local network.
    static func isLocal(_ url: URL) -> Bool {
        guard let scheme = url.scheme?.lowercased(), scheme == "http" || scheme == "https",
              let host = url.host(percentEncoded: false), !host.isEmpty else { return false }
        return isLocalHost(host)
    }

    /// Loopback, unspecified, private and link-local addresses, and the
    /// names local networks and dev tools use (`.local`, `.lan`, `.test`…).
    static func isLocalHost(_ rawHost: String) -> Bool {
        var host = rawHost.lowercased()
        if host.hasPrefix("[") && host.hasSuffix("]") { host = String(host.dropFirst().dropLast()) }
        if host.hasSuffix(".") { host.removeLast() }
        guard !host.isEmpty else { return false }
        if host == "localhost" || host.hasSuffix(".localhost") { return true }
        for suffix in [".local", ".lan", ".home.arpa", ".internal", ".test"] where host.hasSuffix(suffix) {
            return true
        }
        if let octets = ipv4(host) {
            switch (octets[0], octets[1]) {
            case (127, _), (10, _), (192, 168), (169, 254): return true
            case (172, 16...31): return true
            case (0, _): return octets == [0, 0, 0, 0]
            default: return false
            }
        }
        if host.contains(":") {
            // IPv6: loopback, unspecified, unique-local (fc00::/7), link-local.
            if host == "::1" || host == "::" { return true }
            return host.hasPrefix("fc") || host.hasPrefix("fd") || host.hasPrefix("fe80:")
        }
        return false
    }

    private static func ipv4(_ host: String) -> [Int]? {
        let parts = host.split(separator: ".", omittingEmptySubsequences: false)
        guard parts.count == 4 else { return nil }
        let octets = parts.compactMap { part -> Int? in
            guard !part.isEmpty, part.count <= 3, part.allSatisfy(\.isNumber), let value = Int(part), value <= 255 else { return nil }
            return value
        }
        return octets.count == 4 ? octets : nil
    }

    /// The port a URL reaches, its scheme's when it names none.
    static func port(of url: URL) -> Int? {
        if let port = url.port { return port }
        switch url.scheme?.lowercased() {
        case "http": return 80
        case "https": return 443
        default: return nil
        }
    }

    /// What a page is loaded as: a server listening on every interface
    /// (`0.0.0.0`, `::`) is reached through localhost.
    static func loadable(_ url: URL) -> URL {
        guard let host = url.host(percentEncoded: false)?.lowercased(),
              host == "0.0.0.0" || host == "::" || host == "[::]",
              var components = URLComponents(url: url, resolvingAgainstBaseURL: false) else { return url }
        components.host = "localhost"
        return components.url ?? url
    }

    /// The http(s) address in a line of terminal text that covers `column`
    /// (a character offset), for opening a link with a plain click.
    static func url(inLine line: String, column: Int) -> URL? {
        let characters = Array(line)
        guard column >= 0, column < characters.count else { return nil }
        let text = String(characters)
        guard let pattern = try? NSRegularExpression(pattern: #"https?://[^\s<>"'`|]+"#, options: [.caseInsensitive]) else { return nil }
        let ns = text as NSString
        for match in pattern.matches(in: text, range: NSRange(location: 0, length: ns.length)) {
            var candidate = ns.substring(with: match.range)
            candidate = trimTrailing(candidate)
            // Character offsets, as the terminal's columns are.
            let start = ns.substring(to: match.range.location).count
            let end = start + candidate.count
            guard column >= start, column < end else { continue }
            guard let url = URL(string: candidate), url.host(percentEncoded: false)?.isEmpty == false else { return nil }
            return url
        }
        return nil
    }

    /// Drops what ends a sentence rather than the address: "see
    /// http://localhost:3000." or "(http://localhost:3000)".
    private static func trimTrailing(_ candidate: String) -> String {
        var result = candidate
        while let last = result.last {
            if ".,;:!?'\"".contains(last) {
                result.removeLast()
            } else if last == ")" && result.filter({ $0 == "(" }).count < result.filter({ $0 == ")" }).count {
                result.removeLast()
            } else if last == "]" && !result.contains("[") {
                result.removeLast()
            } else if last == "}" && !result.contains("{") {
                result.removeLast()
            } else {
                break
            }
        }
        return result
    }
}

/// A page visited in the Browser plane, for the "Recent" list.
struct PreviewRecent: Codable, Equatable, Identifiable {
    var url: String
    var title: String?
    var visitedAt: Date
    var id: String { url }
}

/// Pages visited in the Browser plane, newest first, kept per project folder
/// (T3 Code keeps them per thread) and capped so the list stays short.
final class PreviewRecentsStore {
    static let perFolderLimit = 12
    static let folderLimit = 60
    private let defaults: UserDefaults
    private let key: String

    init(defaults: UserDefaults = .standard, key: String = "browser.recents") {
        self.defaults = defaults
        self.key = key
    }

    func entries(for folder: String) -> [PreviewRecent] {
        load()[folder] ?? []
    }

    /// Puts a visit first, replacing an earlier one to the same address.
    /// Only web pages count; a title left out keeps the one known before.
    func record(_ url: URL, title: String?, folder: String, at date: Date = Date()) {
        guard let scheme = url.scheme?.lowercased(), scheme == "http" || scheme == "https",
              url.host(percentEncoded: false)?.isEmpty == false else { return }
        let address = Self.key(for: url)
        var all = load()
        var list = all[folder] ?? []
        let earlier = list.first { $0.url == address }
        list.removeAll { $0.url == address }
        let cleanTitle = title?.trimmingCharacters(in: .whitespacesAndNewlines)
        let named = (cleanTitle?.isEmpty == false) ? cleanTitle : earlier?.title
        list.insert(PreviewRecent(url: address, title: named, visitedAt: date), at: 0)
        all[folder] = Array(list.prefix(Self.perFolderLimit))
        if all.count > Self.folderLimit {
            // The folders visited longest ago go first.
            let newest = all.mapValues { $0.first?.visitedAt ?? .distantPast }
            for (stale, _) in newest.sorted(by: { $0.value < $1.value }).prefix(all.count - Self.folderLimit) {
                all[stale] = nil
            }
        }
        save(all)
    }

    func remove(_ address: String, folder: String) {
        var all = load()
        all[folder]?.removeAll { $0.url == address }
        if all[folder]?.isEmpty == true { all[folder] = nil }
        save(all)
    }

    /// One entry per page: the fragment doesn't make another.
    static func key(for url: URL) -> String {
        guard var components = URLComponents(url: url, resolvingAgainstBaseURL: false) else { return url.absoluteString }
        components.fragment = nil
        return components.url?.absoluteString ?? url.absoluteString
    }

    private func load() -> [String: [PreviewRecent]] {
        guard let data = defaults.data(forKey: key),
              let decoded = try? JSONDecoder().decode([String: [PreviewRecent]].self, from: data) else { return [:] }
        return decoded
    }

    private func save(_ all: [String: [PreviewRecent]]) {
        if let data = try? JSONEncoder().encode(all) { defaults.set(data, forKey: key) }
    }
}

/// Where a site's icon is: the page's `<link rel="icon">`, else
/// `/favicon.ico` at its origin.
enum PreviewFavicon {
    /// One icon per origin.
    static func cacheKey(for url: URL) -> String? {
        guard let scheme = url.scheme?.lowercased(), let host = url.host(percentEncoded: false)?.lowercased() else { return nil }
        return "\(scheme)://\(host)" + (url.port.map { ":\($0)" } ?? "")
    }

    static func fallbackURL(for page: URL) -> URL? {
        guard let origin = cacheKey(for: page) else { return nil }
        return URL(string: origin + "/favicon.ico")
    }

    /// The best icon a page names, resolved against the page: a plain icon
    /// first, then an Apple touch icon, then an SVG one.
    static func iconURL(inHTML html: String, page: URL) -> URL? {
        guard let linkPattern = try? NSRegularExpression(pattern: #"<link\b[^>]*>"#, options: [.caseInsensitive]) else { return nil }
        let ns = html as NSString
        var best: (rank: Int, url: URL)?
        var base = page
        if let baseHref = attribute("href", in: firstTag("base", in: html) ?? ""),
           let resolved = URL(string: baseHref, relativeTo: page)?.absoluteURL {
            base = resolved
        }
        for match in linkPattern.matches(in: html, range: NSRange(location: 0, length: ns.length)) {
            let tag = ns.substring(with: match.range)
            guard let rel = attribute("rel", in: tag)?.lowercased(),
                  let href = attribute("href", in: tag), !href.isEmpty else { continue }
            let tokens = Set(rel.split(whereSeparator: \.isWhitespace).map(String.init))
            let isSVG = attribute("type", in: tag)?.lowercased().contains("svg") == true || href.lowercased().hasSuffix(".svg")
            let rank: Int
            if tokens.contains("icon") { rank = isSVG ? 2 : 0 }
            else if tokens.contains("apple-touch-icon") || tokens.contains("apple-touch-icon-precomposed") { rank = 1 }
            else { continue }
            let decoded = href.replacingOccurrences(of: "&amp;", with: "&")
            guard let url = URL(string: decoded, relativeTo: base)?.absoluteURL else { continue }
            if best == nil || rank < best!.rank { best = (rank, url) }
        }
        return best?.url
    }

    private static func firstTag(_ name: String, in html: String) -> String? {
        guard let pattern = try? NSRegularExpression(pattern: "<\(name)\\b[^>]*>", options: [.caseInsensitive]),
              let match = pattern.firstMatch(in: html, range: NSRange(location: 0, length: (html as NSString).length)) else { return nil }
        return (html as NSString).substring(with: match.range)
    }

    /// An attribute's value in a tag, quoted or not.
    static func attribute(_ name: String, in tag: String) -> String? {
        let pattern = #"(?:^|[\s<])"# + NSRegularExpression.escapedPattern(for: name)
            + #"\s*=\s*(?:"([^"]*)"|'([^']*)'|([^\s"'>]+))"#
        guard let regex = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive]),
              let match = regex.firstMatch(in: tag, range: NSRange(location: 0, length: (tag as NSString).length)) else { return nil }
        for group in 1...3 {
            let range = match.range(at: group)
            if range.location != NSNotFound { return (tag as NSString).substring(with: range) }
        }
        return nil
    }
}

/// What a dev server is called, from `ServiceKind`'s logo slug.
enum PreviewServiceName {
    private static let names: [String: String] = [
        "nodedotjs": "Node.js", "bun": "Bun", "deno": "Deno", "vite": "Vite", "nextdotjs": "Next.js",
        "nuxt": "Nuxt", "remix": "Remix", "gatsby": "Gatsby", "storybook": "Storybook", "angular": "Angular",
        "expo": "Expo", "webpack": "webpack", "esbuild": "esbuild", "electron": "Electron", "django": "Django",
        "fastapi": "FastAPI", "flask": "Flask", "streamlit": "Streamlit", "gradio": "Gradio", "jupyter": "Jupyter",
        "gunicorn": "Gunicorn", "rubyonrails": "Rails", "laravel": "Laravel", "phoenixframework": "Phoenix",
        "hugo": "Hugo", "jekyll": "Jekyll", "ollama": "Ollama", "supabase": "Supabase", "prisma": "Prisma",
        "nginx": "nginx", "python": "Python", "ruby": "Ruby", "go": "Go", "rust": "Rust", "php": "PHP",
        "astro": "Astro", "svelte": "SvelteKit", "docker": "Docker",
    ]

    static func display(_ slug: String?) -> String? {
        guard let slug, !slug.isEmpty else { return nil }
        return names[slug] ?? slug.prefix(1).uppercased() + slug.dropFirst()
    }
}

/// A page that couldn't be loaded, in words, after T3 Code's
/// `PreviewUnreachable`.
enum PreviewLoadError {
    /// A short reason, e.g. "refused to connect".
    static func reason(code: Int, fallback: String) -> String {
        switch code {
        case NSURLErrorCannotConnectToHost: "refused to connect"
        case NSURLErrorTimedOut: "took too long to respond"
        case NSURLErrorCannotFindHost, NSURLErrorDNSLookupFailed: "the server's address couldn't be found"
        case NSURLErrorNotConnectedToInternet: "you're not connected to a network"
        case NSURLErrorNetworkConnectionLost: "the connection was lost"
        case NSURLErrorSecureConnectionFailed, NSURLErrorServerCertificateUntrusted,
             NSURLErrorServerCertificateHasBadDate, NSURLErrorServerCertificateNotYetValid,
             NSURLErrorServerCertificateHasUnknownRoot: "a secure connection couldn't be made"
        case NSURLErrorBadServerResponse: "sent a response that couldn't be read"
        default: fallback.isEmpty ? "the page couldn't be loaded" : fallback
        }
    }

    /// The machine-readable label shown under it, as browsers do.
    static func label(code: Int) -> String {
        switch code {
        case NSURLErrorCannotConnectToHost: "ERR_CONNECTION_REFUSED"
        case NSURLErrorTimedOut: "ERR_TIMED_OUT"
        case NSURLErrorCannotFindHost, NSURLErrorDNSLookupFailed: "ERR_NAME_NOT_RESOLVED"
        case NSURLErrorNotConnectedToInternet: "ERR_INTERNET_DISCONNECTED"
        case NSURLErrorNetworkConnectionLost: "ERR_CONNECTION_RESET"
        case NSURLErrorSecureConnectionFailed: "ERR_SSL_PROTOCOL_ERROR"
        default: "ERR_\(abs(code))"
        }
    }

    /// Whether a server coming up could fix it, so it's worth waiting for.
    static func serverMayComeBack(code: Int) -> Bool {
        [NSURLErrorCannotConnectToHost, NSURLErrorTimedOut, NSURLErrorNetworkConnectionLost,
         NSURLErrorBadServerResponse, NSURLErrorCannotFindHost].contains(code)
    }
}

/// The page zoom steps ⌘+ and ⌘− move between, as Safari's.
enum PreviewZoom {
    static let steps: [Double] = [0.5, 0.67, 0.75, 0.8, 0.9, 1, 1.1, 1.25, 1.5, 1.75, 2, 2.5, 3]

    static func zoomIn(from value: Double) -> Double {
        steps.first { $0 > value + 0.001 } ?? steps.last!
    }

    static func zoomOut(from value: Double) -> Double {
        steps.last { $0 < value - 0.001 } ?? steps.first!
    }

    static func label(_ value: Double) -> String { "\(Int((value * 100).rounded()))%" }
}
