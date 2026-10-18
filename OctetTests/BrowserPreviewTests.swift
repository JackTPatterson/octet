import XCTest

final class PreviewLinkTests: XCTestCase {
    private func local(_ string: String) -> Bool { PreviewLink.isLocal(URL(string: string)!) }

    func testLocalAddresses() {
        XCTAssertTrue(local("http://localhost:5173/"))
        XCTAssertTrue(local("http://LOCALHOST:3000"))
        XCTAssertTrue(local("https://app.localhost:8443/x"))
        XCTAssertTrue(local("http://127.0.0.1:8000/docs"))
        XCTAssertTrue(local("http://127.1.2.3"))
        XCTAssertTrue(local("http://0.0.0.0:4321"))
        XCTAssertTrue(local("http://[::1]:5173/"))
        XCTAssertTrue(local("http://192.168.86.55:8025"))
        XCTAssertTrue(local("http://10.0.0.4:3000"))
        XCTAssertTrue(local("http://172.20.1.1"))
        XCTAssertTrue(local("http://169.254.1.1"))
        XCTAssertTrue(local("http://mailpit.lan:8025"))
        XCTAssertTrue(local("http://my-mac.local:3000"))
        XCTAssertTrue(local("http://shop.test"))
    }

    func testOtherAddressesAreNotLocal() {
        XCTAssertFalse(local("https://github.com/JackTPatterson"))
        XCTAssertFalse(local("http://example.com:3000"))
        XCTAssertFalse(local("http://172.32.0.1"))
        XCTAssertFalse(local("http://8.8.8.8"))
        XCTAssertFalse(local("http://192.169.0.1"))
        XCTAssertFalse(local("http://localhost.example.com"))
        XCTAssertFalse(local("http://1.0.0.0"))
        XCTAssertFalse(local("file:///tmp/index.html"))
        XCTAssertFalse(local("ftp://localhost/"))
        XCTAssertFalse(local("mailto:me@localhost"))
        XCTAssertFalse(local("http://999.1.1.1"))
    }

    func testLoadableAndPort() {
        XCTAssertEqual(PreviewLink.loadable(URL(string: "http://0.0.0.0:4321/a?b=1")!).absoluteString, "http://localhost:4321/a?b=1")
        XCTAssertEqual(PreviewLink.loadable(URL(string: "http://127.0.0.1:3000")!).absoluteString, "http://127.0.0.1:3000")
        XCTAssertEqual(PreviewLink.port(of: URL(string: "http://localhost:5173")!), 5173)
        XCTAssertEqual(PreviewLink.port(of: URL(string: "http://localhost")!), 80)
        XCTAssertEqual(PreviewLink.port(of: URL(string: "https://localhost")!), 443)
    }

    func testURLInTerminalLine() {
        let line = "  ➜  Local:   http://localhost:5173/   (press h for help)"
        let start = Array(line).firstIndex(of: "h")!
        XCTAssertEqual(PreviewLink.url(inLine: line, column: start)?.absoluteString, "http://localhost:5173/")
        XCTAssertEqual(PreviewLink.url(inLine: line, column: start + 12)?.absoluteString, "http://localhost:5173/")
        XCTAssertNil(PreviewLink.url(inLine: line, column: 2))
        XCTAssertNil(PreviewLink.url(inLine: line, column: 500))
        // Sentence punctuation and wrapping parentheses aren't the address.
        let prose = "Server ready (http://127.0.0.1:8000)."
        let at = Array(prose).firstIndex(of: "h")!
        XCTAssertEqual(PreviewLink.url(inLine: prose, column: at + 3)?.absoluteString, "http://127.0.0.1:8000")
        XCTAssertNil(PreviewLink.url(inLine: prose, column: prose.count - 1))
        // A path with balanced parentheses keeps them.
        let wiki = "see https://en.wikipedia.org/wiki/Foo_(bar) now"
        XCTAssertEqual(PreviewLink.url(inLine: wiki, column: 6)?.absoluteString, "https://en.wikipedia.org/wiki/Foo_(bar)")
        // Two links on a line: the one under the column.
        let two = "a http://localhost:3000 b http://localhost:4000"
        XCTAssertEqual(PreviewLink.url(inLine: two, column: 30)?.port, 4000)
    }
}

final class PreviewRecentsStoreTests: XCTestCase {
    private var defaults: UserDefaults!
    private let suite = "octet.tests.browser-recents.\(UUID().uuidString)"

    override func setUp() {
        defaults = UserDefaults(suiteName: suite)
    }

    override func tearDown() {
        defaults.removePersistentDomain(forName: suite)
    }

    func testNewestFirstDedupedAndPerFolder() {
        let store = PreviewRecentsStore(defaults: defaults, key: "recents")
        let start = Date(timeIntervalSince1970: 1_000)
        store.record(URL(string: "http://localhost:5173/")!, title: "App", folder: "/a", at: start)
        store.record(URL(string: "http://localhost:3000/")!, title: nil, folder: "/a", at: start.addingTimeInterval(1))
        store.record(URL(string: "http://localhost:5173/#top")!, title: "  ", folder: "/a", at: start.addingTimeInterval(2))
        store.record(URL(string: "http://localhost:8080/")!, title: "Other", folder: "/b", at: start)
        let a = store.entries(for: "/a")
        XCTAssertEqual(a.map(\.url), ["http://localhost:5173/", "http://localhost:3000/"])
        // A blank title keeps the one known before.
        XCTAssertEqual(a.first?.title, "App")
        XCTAssertEqual(store.entries(for: "/b").map(\.url), ["http://localhost:8080/"])
        // Persisted: a new store over the same defaults reads them back.
        XCTAssertEqual(PreviewRecentsStore(defaults: defaults, key: "recents").entries(for: "/a").count, 2)
    }

    func testCappedAndOnlyWebPages() {
        let store = PreviewRecentsStore(defaults: defaults, key: "recents")
        for port in 3000..<(3000 + PreviewRecentsStore.perFolderLimit + 5) {
            store.record(URL(string: "http://localhost:\(port)")!, title: nil, folder: "/p")
        }
        let entries = store.entries(for: "/p")
        XCTAssertEqual(entries.count, PreviewRecentsStore.perFolderLimit)
        XCTAssertEqual(entries.first?.url, "http://localhost:\(3000 + PreviewRecentsStore.perFolderLimit + 4)")
        store.record(URL(string: "file:///tmp/x.html")!, title: nil, folder: "/q")
        store.record(URL(string: "about:blank")!, title: nil, folder: "/q")
        XCTAssertTrue(store.entries(for: "/q").isEmpty)
    }

    func testRemoveAndFolderCap() {
        let store = PreviewRecentsStore(defaults: defaults, key: "recents")
        store.record(URL(string: "http://localhost:1234")!, title: nil, folder: "/r")
        store.remove("http://localhost:1234", folder: "/r")
        XCTAssertTrue(store.entries(for: "/r").isEmpty)
        let start = Date(timeIntervalSince1970: 0)
        for index in 0...(PreviewRecentsStore.folderLimit) {
            store.record(URL(string: "http://localhost:3000")!, title: nil, folder: "/f\(index)",
                         at: start.addingTimeInterval(Double(index)))
        }
        // The folder visited longest ago made room.
        XCTAssertTrue(store.entries(for: "/f0").isEmpty)
        XCTAssertFalse(store.entries(for: "/f\(PreviewRecentsStore.folderLimit)").isEmpty)
    }
}

final class PreviewFaviconTests: XCTestCase {
    private let page = URL(string: "http://localhost:5173/app/index.html")!

    func testFallbackAndKey() {
        XCTAssertEqual(PreviewFavicon.fallbackURL(for: page)?.absoluteString, "http://localhost:5173/favicon.ico")
        XCTAssertEqual(PreviewFavicon.cacheKey(for: URL(string: "https://Example.com/a/b")!), "https://example.com")
        XCTAssertEqual(PreviewFavicon.cacheKey(for: page), "http://localhost:5173")
    }

    func testLinkTagsResolveAgainstThePage() {
        let html = """
        <html><head>
        <link rel="stylesheet" href="/style.css">
        <link rel="icon" type="image/svg+xml" href="/vite.svg" />
        <link rel='apple-touch-icon' href='touch.png'>
        <LINK REL="shortcut icon" HREF=favicon.png>
        </head></html>
        """
        // A plain icon beats the touch icon, which beats an SVG one.
        XCTAssertEqual(PreviewFavicon.iconURL(inHTML: html, page: page)?.absoluteString, "http://localhost:5173/app/favicon.png")
        let touchOnly = #"<link rel="apple-touch-icon" href="touch.png"><link rel="icon" href="/i.svg">"#
        XCTAssertEqual(PreviewFavicon.iconURL(inHTML: touchOnly, page: page)?.absoluteString, "http://localhost:5173/app/touch.png")
        let svgOnly = #"<link href="/vite.svg" rel="icon">"#
        XCTAssertEqual(PreviewFavicon.iconURL(inHTML: svgOnly, page: page)?.absoluteString, "http://localhost:5173/vite.svg")
        let absolute = #"<link rel="icon" href="https://cdn.example.com/i.png?v=1&amp;x=2">"#
        XCTAssertEqual(PreviewFavicon.iconURL(inHTML: absolute, page: page)?.absoluteString, "https://cdn.example.com/i.png?v=1&x=2")
        let based = #"<base href="/static/"><link rel="icon" href="fav.ico">"#
        XCTAssertEqual(PreviewFavicon.iconURL(inHTML: based, page: page)?.absoluteString, "http://localhost:5173/static/fav.ico")
        XCTAssertNil(PreviewFavicon.iconURL(inHTML: "<html><title>x</title></html>", page: page))
        // "rel" inside another attribute's value isn't the rel attribute.
        XCTAssertNil(PreviewFavicon.iconURL(inHTML: #"<link data-rel="icon" href="/x.png">"#, page: page))
    }
}

final class PreviewZoomAndErrorTests: XCTestCase {
    func testZoomSteps() {
        XCTAssertEqual(PreviewZoom.zoomIn(from: 1), 1.1)
        XCTAssertEqual(PreviewZoom.zoomOut(from: 1), 0.9)
        XCTAssertEqual(PreviewZoom.zoomIn(from: 3), 3)
        XCTAssertEqual(PreviewZoom.zoomOut(from: 0.5), 0.5)
        XCTAssertEqual(PreviewZoom.zoomIn(from: 1.05), 1.1)
        XCTAssertEqual(PreviewZoom.label(1.25), "125%")
    }

    func testErrors() {
        XCTAssertEqual(PreviewLoadError.label(code: NSURLErrorCannotConnectToHost), "ERR_CONNECTION_REFUSED")
        XCTAssertEqual(PreviewLoadError.reason(code: NSURLErrorCannotConnectToHost, fallback: "x"), "refused to connect")
        XCTAssertEqual(PreviewLoadError.reason(code: 12_345, fallback: "Odd"), "Odd")
        XCTAssertTrue(PreviewLoadError.serverMayComeBack(code: NSURLErrorCannotConnectToHost))
        XCTAssertFalse(PreviewLoadError.serverMayComeBack(code: NSURLErrorSecureConnectionFailed))
        XCTAssertEqual(PreviewServiceName.display("nextdotjs"), "Next.js")
        XCTAssertEqual(PreviewServiceName.display("zola"), "Zola")
        XCTAssertNil(PreviewServiceName.display(nil))
    }
}
