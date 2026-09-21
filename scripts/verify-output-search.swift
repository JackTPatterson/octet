// Native Find smoke test with a stubbed engine; never touches live sessions.
// swiftc -parse-as-library -module-cache-path /tmp/octet-smoke-modules \
//   Octet/Terminal/OutputSearch.swift Shared/TerminalSearch.swift \
//   scripts/verify-output-search.swift -o /tmp/octet-find-smoke
// /tmp/octet-find-smoke
import AppKit
import Foundation

enum EngineSocketError: Error {
    case malformedResponse(String)
    case server(code: String, message: String)
}
final class SearchFixture: @unchecked Sendable {
    let lock = NSLock()
    var offsets: [Int] = []
    var closed = false
    var slowViewport = false
    func request(_ method: String, _ params: [String: Any]) throws -> [String: Any] {
        lock.lock(); defer { lock.unlock() }
        precondition(params["pane_id"] as? String == "test:p1")
        if closed { throw EngineSocketError.server(code: "not_found", message: "Pane closed") }
        switch method {
        case "pane.copy_motion": return ["content_revision": UInt64(42)]
        case "pane.get":
            if slowViewport { Thread.sleep(forTimeInterval: 0.2) }
            return ["pane": ["scroll": ["max_offset_from_bottom": 10000, "viewport_rows": 40]]]
        case "pane.scroll": offsets.append(params["offset_from_bottom"] as! Int); return [:]
        case "pane.copy_search":
            precondition(params["query"] as? String == "needle 日本語")
            let later = params["previous"] != nil && params["direction"] as? String == "forward"
            let row = later ? 9000 : 100
            return ["pane_id": "test:p1", "content_revision": UInt64(42), "total": 2000,
                    "current": 0, "current_global": later ? 1500 : 0,
                    "matches": [["start": ["row": row, "col": 0], "end": ["row": row, "col": 10]]]]
        default: fatalError("Unexpected method: \(method)")
        }
    }
    func recordedOffsets() -> [Int] { lock.lock(); defer { lock.unlock() }; return offsets }
    func delayViewport() { lock.lock(); defer { lock.unlock() }; slowViewport = true }
    func closePane() { lock.lock(); defer { lock.unlock() }; closed = true }
}
struct EngineClient: Sendable {
    let fixture: SearchFixture
    func call(_ method: String, _ params: [String: Any]) throws -> [String: Any] { try fixture.request(method, params) }
}
@MainActor final class Context {
    var nsWindow: NSWindow?
    var surface: NSView?
    func findOutput(_ action: NSTextFinder.Action) {}
}
@MainActor final class WindowRegistry {
    static let shared = WindowRegistry()
    var windows: [Context] = []
}
func descendants(_ v: NSView) -> [NSView] { [v] + v.subviews.flatMap(descendants) }
@main
@MainActor
struct OutputSearchSmoke {
    static func main() {
        let app = NSApplication.shared
        app.setActivationPolicy(.accessory)
        app.finishLaunching()
        let parent = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 1000, height: 700), styleMask: [.titled], backing: .buffered, defer: false)
        parent.makeKeyAndOrderFront(nil)
        let fixture = SearchFixture()
        let search = OutputSearch(client: EngineClient(fixture: fixture), paneId: "test:p1")
        search.present(on: parent)
        let fields = descendants(search.window!.contentView!).compactMap { $0 as? NSTextField }
        let query = fields.compactMap { $0 as? NSSearchField }.first!
        query.stringValue = "needle 日本語"
        search.find(.nextMatch)
        RunLoop.current.run(until: Date().addingTimeInterval(0.5))
        precondition(fixture.recordedOffsets() == [9920])
        search.find(.nextMatch)
        RunLoop.current.run(until: Date().addingTimeInterval(0.5))
        precondition(fixture.recordedOffsets() == [9920, 1020])
        precondition(fields.contains { $0.stringValue.contains("1501 of 2000") })
        search.find(.previousMatch)
        RunLoop.current.run(until: Date().addingTimeInterval(0.5))
        precondition(fixture.recordedOffsets().last == 9920)
        fixture.delayViewport()
        search.find(.nextMatch)
        RunLoop.current.run(until: Date().addingTimeInterval(0.05))
        precondition(search.control(query, textView: NSTextView(), doCommandBy: #selector(NSResponder.cancelOperation(_:))))
        RunLoop.current.run(until: Date().addingTimeInterval(0.4))
        precondition(fixture.recordedOffsets().count == 3, "Dismissed search must not scroll")
        search.present(on: parent)
        query.stringValue = "needle 日本語"
        fixture.closePane()
        search.find(.nextMatch)
        RunLoop.current.run(until: Date().addingTimeInterval(0.5))
        precondition(fields.contains { $0.stringValue.contains("Couldn't search") })
        precondition(fixture.recordedOffsets().count == 3)
        search.dismiss()
        precondition(search.window!.parent == nil && !search.window!.isVisible)
        print("PASS: native query, global match counts, next/previous live scrolling, closed-pane error, Escape dismissal and cancellation before scrolling")
    }
}
