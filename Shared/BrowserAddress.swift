import Foundation

/// What the Browser plane's address field means: a port is a local server,
/// a host with a dot is a site, anything else is a search.
enum BrowserAddress {
    static func url(from text: String) -> URL? {
        let input = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !input.isEmpty else { return nil }
        if Int(input).map({ (1...65_535).contains($0) }) == true {
            return URL(string: "http://localhost:\(input)")
        }
        if input.contains("://") { return URL(string: input) }
        let authority = input.split(separator: "/").first.map(String.init) ?? input
        // The host without its port, so "mailpit.lan:8025" still reads as local.
        let host = authority.split(separator: ":").first.map(String.init) ?? authority
        let local = host.hasPrefix("localhost") || host.hasPrefix("127.0.0.1") || host.hasPrefix("0.0.0.0")
            || host.hasSuffix(".local") || host.hasSuffix(".lan") || host.hasSuffix(".ts.net")
        if local { return URL(string: "http://" + input) }
        if !input.contains(" "), host.contains(".") { return URL(string: "https://" + input) }
        var search = URLComponents(string: "https://duckduckgo.com/")!
        search.queryItems = [URLQueryItem(name: "q", value: input)]
        return search.url
    }
}
