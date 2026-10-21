import XCTest
import WebKit
import SwiftUI
@testable import Octet

@MainActor
final class BrowserPickerIntegrationTests: XCTestCase {
    private func js(_ source: String, page: BrowserPage) async throws -> Any? {
        try await withCheckedThrowingContinuation { continuation in
            page.view.evaluateJavaScript(source, in: nil, in: BrowserAnnotations.world) { result in
                continuation.resume(with: result)
            }
        }
    }
    func testResponsiveViewportChangesActualWebKitLayout() async throws {
        let page = BrowserPage(private: true)
        let host = NSHostingView(rootView: BrowserViewportView(page: page))
        let window = NSWindow(contentRect: NSRect(x: 100, y: 100, width: 820, height: 600), styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = host
        window.makeKeyAndOrderFront(nil)
        defer { window.orderOut(nil); window.contentView = nil }
        page.view.loadHTMLString("<html><head><meta name='viewport' content='width=device-width, initial-scale=1'></head><body>Responsive fixture</body></html>", baseURL: URL(string: "https://example.test"))
        page.viewport = .phone
        for _ in 0..<100 {
            host.layoutSubtreeIfNeeded()
            if (try? await js("window.innerWidth", page: page)) as? Int == 390 { break }
            try await Task.sleep(nanoseconds: 20_000_000)
        }
        let phoneWidth = try await js("window.innerWidth", page: page) as? Int
        XCTAssertEqual(phoneWidth, 390)
        let mobile = try await js("matchMedia('(max-width: 400px)').matches", page: page) as? Bool
        XCTAssertEqual(mobile, true)
        page.viewport = .desktop
        for _ in 0..<100 {
            host.layoutSubtreeIfNeeded()
            if ((try? await js("window.innerWidth", page: page)) as? Int ?? 0) > 700 { break }
            try await Task.sleep(nanoseconds: 20_000_000)
        }
        let width = try await js("window.innerWidth", page: page) as? Int
        XCTAssertGreaterThan(width ?? 0, 700)
    }

    func testPickerCapturesElementScreenshotAndRedactsFormValues() async throws {
        let page = BrowserPage(private: true)
        let window = NSWindow(contentRect: NSRect(x: 100, y: 100, width: 720, height: 500),
                              styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = page.view
        window.makeKeyAndOrderFront(nil)
        defer { window.orderOut(nil); window.contentView = nil }
        page.view.loadHTMLString("""
        <!doctype html><html><head><title>Picker test</title></head>
        <body style="background:#fff;padding:40px;font:18px sans-serif">
        <section id="card" style="padding:20px;border:1px solid #ccc">
        <button id="target" style="padding:15px;background:blue;color:white">Save changes</button>
        <input type="password" value="never-send-this"><script>window.shouldNotCopy='private';</script>
        </section></body></html>
        """, baseURL: URL(string: "https://example.test/picker"))
        var ready = false
        for _ in 0..<200 {
            if (try? await js("!!globalThis.octetPicker && !!document.getElementById('target')", page: page)) as? Bool == true { ready = true; break }
            try await Task.sleep(nanoseconds: 25_000_000)
        }
        XCTAssertTrue(ready)
        let filtered = try await js("document.getElementById('card').querySelector('input').value", page: page) as? String
        XCTAssertEqual(filtered, "never-send-this", "Fixture really contains a private form value")
        page.annotations.toggle()
        for _ in 0..<100 {
            if page.annotations.picking { break }
            try await Task.sleep(nanoseconds: 10_000_000)
        }
        XCTAssertTrue(page.annotations.picking)
        _ = try await js("document.getElementById('card').dispatchEvent(new MouseEvent('click',{bubbles:true,cancelable:true})); true", page: page)
        for _ in 0..<200 {
            if !page.annotations.items.isEmpty { break }
            try await Task.sleep(nanoseconds: 25_000_000)
        }
        let item = try XCTUnwrap(page.annotations.items.first, page.annotations.failure ?? "No captured item; picking=\(page.annotations.picking) capturing=\(page.annotations.capturing) url=\(page.view.url?.absoluteString ?? "nil")")
        XCTAssertEqual(item.context.selector, "#card")
        XCTAssertTrue(item.context.html.contains("Save changes"))
        XCTAssertFalse(item.context.html.contains("never-send-this"))
        XCTAssertFalse(item.context.html.contains("shouldNotCopy"))
        XCTAssertNotNil(item.screenshot)
        if let data = item.screenshot { try data.write(to: URL(fileURLWithPath: "/private/tmp/octet-browser-picker-test.png")) }
        XCTAssertFalse(page.annotations.picking)
        page.annotations.items[0].note = "Make this button less saturated and add more padding."
        let store = SessionStore(client: Octet.EngineClient(socketPath: "/tmp/octet-unused-picker-test.sock"))
        let context = WindowContext(spec: OctetWindowSpec(), store: store)
        let hosting = NSHostingView(rootView: BrowserAnnotationTray(annotations: page.annotations, directory: "/tmp")
            .environmentObject(context).frame(width: 420))
        window.contentView = hosting
        window.setContentSize(NSSize(width: 420, height: 340))
        try await Task.sleep(nanoseconds: 200_000_000)
        hosting.layoutSubtreeIfNeeded()
        if let bitmap = hosting.bitmapImageRepForCachingDisplay(in: hosting.bounds) {
            hosting.cacheDisplay(in: hosting.bounds, to: bitmap)
            try bitmap.representation(using: .png, properties: [:])?.write(to: URL(fileURLWithPath: "/private/tmp/octet-browser-tray-test.png"))
        }
        page.annotations.clear()
        XCTAssertTrue(page.annotations.items.isEmpty)
    }
}
