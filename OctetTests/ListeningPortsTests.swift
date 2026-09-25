import XCTest

final class ListeningPortsTests: XCTestCase {
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

    func testALoopInTheParentsCantHangIt() {
        XCTAssertEqual(ListeningPorts.byPane([.init(pid: 5, command: "x", port: 1)], parents: [5: 6, 6: 5], shells: [:]), [:])
    }
}
