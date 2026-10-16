import XCTest

final class BrowserAddressTests: XCTestCase {
    func testPortsHostsAndSearches() {
        XCTAssertEqual(BrowserAddress.url(from: "3000")?.absoluteString, "http://localhost:3000")
        XCTAssertEqual(BrowserAddress.url(from: "localhost:5173/app")?.absoluteString, "http://localhost:5173/app")
        XCTAssertEqual(BrowserAddress.url(from: "mailpit.lan:8025")?.absoluteString, "http://mailpit.lan:8025")
        XCTAssertEqual(BrowserAddress.url(from: "example.com")?.absoluteString, "https://example.com")
        XCTAssertEqual(BrowserAddress.url(from: "https://a.b/c")?.absoluteString, "https://a.b/c")
        XCTAssertEqual(BrowserAddress.url(from: "swift ui docs")?.host(), "duckduckgo.com")
        XCTAssertNil(BrowserAddress.url(from: "   "))
    }
}
