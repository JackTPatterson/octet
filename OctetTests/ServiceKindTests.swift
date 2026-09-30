import XCTest

final class ServiceKindTests: XCTestCase {
    private func detect(_ command: String, _ arguments: String, parents: [Int: Int] = [:], more: [Int: String] = [:]) -> String? {
        ServiceKind.detect(pid: 10, command: command, processes: more.merging([10: arguments]) { $1 }, parents: parents)
    }

    func testFrameworksBeatTheirRuntime() {
        XCTAssertEqual(detect("node", "node /app/node_modules/.bin/vite --port 5173"), "vite")
        XCTAssertEqual(detect("node", "node /app/node_modules/vite/bin/vite.js"), "vite")
        XCTAssertEqual(detect("next-server", "next-server (v15.1.0)"), "nextdotjs")
        XCTAssertEqual(detect("Python", "/usr/bin/python3 manage.py runserver"), "django")
        XCTAssertEqual(detect("Python", "python3 -m uvicorn main:app --reload"), "fastapi")
        XCTAssertEqual(detect("ruby", "puma 6.4.2 (tcp://localhost:3000) [app]"), "rubyonrails")
        XCTAssertEqual(detect("postgres", "/opt/homebrew/opt/postgresql@16/bin/postgres -D /data"), "postgresql")
        XCTAssertEqual(detect("redis-server", "redis-server *:6379"), "redis")
    }

    func testARuntimeWhenNothingMoreSpecificShows() {
        XCTAssertEqual(detect("node", "node server.js"), "nodedotjs")
        XCTAssertEqual(detect("Python", "/opt/homebrew/bin/python3.12 -m http.server 8000"), "python")
        XCTAssertEqual(detect("mystery", "./mystery --serve"), nil)
    }

    func testAFrameworkUpTheParents() {
        // `next dev` (pid 5) runs the listening worker as a plain node.
        XCTAssertEqual(detect("node", "node /app/.next/worker.js", parents: [10: 5, 5: 1],
                              more: [5: "node /app/node_modules/.bin/next dev"]), "nextdotjs")
    }

    func testWordsAreWhole() {
        // "bundle" isn't Bun, "vite-app" isn't Vite.
        XCTAssertEqual(detect("ruby", "ruby /x/bundle exec thing"), "ruby")
        XCTAssertEqual(detect("node", "node /code/vite-app/server.js"), "nodedotjs")
    }

    func testParsesPsArguments() {
        let text = "  100     1 -zsh\n  300   200 node /app/node_modules/.bin/vite --host\n"
        XCTAssertEqual(ServiceKind.parseArguments(text), [100: "-zsh", 300: "node /app/node_modules/.bin/vite --host"])
        XCTAssertEqual(ListeningPorts.parseParents(text), [100: 1, 300: 200])
    }
}
