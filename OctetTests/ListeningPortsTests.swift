import XCTest

final class ListeningPortsTests: XCTestCase {
    func testEphemeralPortsAreNeverShown() {
        XCTAssertTrue(ListeningPorts.ephemeral.contains(55564))
        XCTAssertTrue(ListeningPorts.ephemeral.contains(49152))
        XCTAssertFalse(ListeningPorts.ephemeral.contains(3000))
        XCTAssertFalse(ListeningPorts.ephemeral.contains(8080))
    }

    func testOnlyPortsServingAPageAreWorthOpening() {
        XCTAssertEqual(ListeningPorts.probe(response: "HTTP/1.1 200 OK\r\nContent-Type: text/html\r\n"), .page)
        XCTAssertEqual(ListeningPorts.probe(response: "HTTP/1.0 302 Found\r\nLocation: /login\r\n"), .page)
        XCTAssertEqual(ListeningPorts.probe(response: "HTTP/1.1 401 Unauthorized\r\n"), .page)
        XCTAssertEqual(ListeningPorts.probe(response: "HTTP/1.0 200\r\nServer: x\r\n"), .page)
        // A WebSocket or API endpoint, a missing page, or something not HTTP.
        XCTAssertEqual(ListeningPorts.probe(response: "HTTP/1.1 426 Upgrade Required\r\n"), .notPage)
        XCTAssertEqual(ListeningPorts.probe(response: "HTTP/1.1 404 Not Found\r\n"), .notPage)
        XCTAssertEqual(ListeningPorts.probe(response: "Content-Length: 120\r\n\r\n{\"jsonrpc\""), .notPage)
        XCTAssertEqual(ListeningPorts.probe(response: ""), .notPage)
    }

    func testReadsLsofsFieldOutput() {
        let text = "p501\ncnode\nn*:3000\nn[::1]:3000\np777\ncPython\nn127.0.0.1:8765\np900\ncrapportd\nn*:49152\n"
        XCTAssertEqual(ListeningPorts.parseLsof(text), [
            .init(pid: 501, command: "node", port: 3000),
            .init(pid: 777, command: "Python", port: 8765),
            .init(pid: 900, command: "rapportd", port: 49152),
        ])
    }

    func testAPortBelongsToThePaneItsServerDescendsFrom() {
        // shell 100 → npm 200 → node 300 listening; shell 110 → vite 310; launchd's own 900.
        let parents = ListeningPorts.parseParents("  100     1\n  200   100\n  300   200\n  110     1\n  310   110\n  900     1\n")
        let listeners: [ListeningPorts.Listener] = [.init(pid: 300, command: "node", port: 3000),
                                                    .init(pid: 300, command: "node", port: 9229),
                                                    .init(pid: 310, command: "vite", port: 5173),
                                                    .init(pid: 900, command: "rapportd", port: 49152)]
        XCTAssertEqual(ListeningPorts.byPane(listeners, parents: parents, shells: ["w1:p1": 100, "w2:p1": 110]),
                       ["w1:p1": [3000, 9229], "w2:p1": [5173]])
    }

    func testOnlyAPanesOwnServersCanBeStopped() {
        // Shell 100 → node 300 on :3000; launchd's 900 also on :3000 (another address).
        let parents = ListeningPorts.parseParents("  100     1\n  300   100\n  900     1\n")
        let listeners: [ListeningPorts.Listener] = [.init(pid: 300, command: "node", port: 3000),
                                                    .init(pid: 900, command: "rapportd", port: 3000)]
        let owned = ListeningPorts.owned(listeners, parents: parents, shells: ["w1:p1": 100])
        XCTAssertEqual(owned.map(\.0.pid), [300])
        XCTAssertEqual(owned.map(\.1), ["w1:p1"])
    }

    func testALoopInTheParentsCantHangIt() {
        XCTAssertEqual(ListeningPorts.byPane([.init(pid: 5, command: "x", port: 1)], parents: [5: 6, 6: 5], shells: [:]), [:])
    }
}
