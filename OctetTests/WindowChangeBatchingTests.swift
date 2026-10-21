import Combine
import XCTest
@testable import Octet

/// A window passes the store's changes on to its chrome once a turn, and
/// not at all for what only a process scan's own views read.
@MainActor
final class WindowChangeBatchingTests: XCTestCase {
    func testSeveralStoreChangesInOneTurnRedrawTheWindowOnce() {
        let store = SessionStore(client: Octet.EngineClient(socketPath: "/tmp/octet-unused-batching-test.sock"))
        let window = WindowContext(spec: OctetWindowSpec(), store: store)
        var storeSends = 0
        var windowSends = 0
        let watches = [store.objectWillChange.sink { storeSends += 1 },
                       window.objectWillChange.sink { windowSends += 1 }]
        store.lastError = "one"
        store.lastError = "two"
        store.lastError = nil
        XCTAssertEqual(storeSends, 3)
        XCTAssertEqual(windowSends, 1)

        // The next turn's change is passed on again.
        let turn = expectation(description: "next turn")
        DispatchQueue.main.async { turn.fulfill() }
        wait(for: [turn], timeout: 1)
        store.lastError = "three"
        XCTAssertEqual(windowSends, 2)
        withExtendedLifetime(watches) {}
    }
}
