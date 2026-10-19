import XCTest
@testable import Octet

@MainActor
final class WorkspaceSetupCompletionTests: XCTestCase {
    private func fixture() throws -> (URL, String, String, UserDefaults, SessionStore) {
        let base = FileManager.default.temporaryDirectory.appendingPathComponent("setup-test-" + UUID().uuidString)
        let root = base.appendingPathComponent("repo").path, checkout = base.appendingPathComponent("wt").path
        try FileManager.default.createDirectory(atPath: root, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(atPath: checkout, withIntermediateDirectories: true)
        let git = Process(); git.executableURL = URL(fileURLWithPath: "/usr/bin/git")
        git.arguments = ["init", "-q", root]; try git.run(); git.waitUntilExit()
        let defaults = UserDefaults(suiteName: base.lastPathComponent)!
        defaults.set([root], forKey: "octet.worktreeSetup.trustedRepos")
        let store = SessionStore(client: Octet.EngineClient(socketPath: base.appendingPathComponent("unused.socket").path))
        return (base, root, checkout, defaults, store)
    }
    private func result(_ root: String, _ checkout: String) -> [String: Any] {
        ["workspace": ["worktree": ["repo_root": root, "checkout_path": checkout]]]
    }
    private func eventually(_ condition: () -> Bool) async throws {
        for _ in 0..<200 {
            if condition() { return }
            try await Task.sleep(nanoseconds: 25_000_000)
        }
        XCTFail("Setup did not settle within five seconds")
    }
    private func write(_ command: String, checkout: String, wait: Bool = true) throws {
        let data = try JSONSerialization.data(withJSONObject: ["setup": command, "waitForSetup": wait])
        try data.write(to: URL(fileURLWithPath: checkout + "/octet.json"))
    }

    func testAgentWaitsForSuccessfulExitAndOutputIsLogged() async throws {
        let (base, root, checkout, defaults, store) = try fixture()
        defer { try? FileManager.default.removeItem(at: base); defaults.removePersistentDomain(forName: base.lastPathComponent) }
        let runner = WorktreeSetupRunner(defaults: defaults, logsDirectory: base.appendingPathComponent("logs"), enabled: { true })
        try write("sleep 0.15; printf setup-finished; touch ready", checkout: checkout)
        var releases = 0
        runner.run(after: result(root, checkout), store: store) {
            XCTAssertTrue(FileManager.default.fileExists(atPath: checkout + "/ready")); releases += 1
        }
        XCTAssertEqual(releases, 0)
        try await eventually { runner.state(for: checkout)?.phase == .ready }
        XCTAssertEqual(releases, 1)
        let log = try XCTUnwrap(runner.state(for: checkout)?.logPath)
        XCTAssertTrue(try String(contentsOfFile: log, encoding: .utf8).contains("setup-finished"))
    }

    func testFailureHoldsAgentAndRetryReleasesItOnce() async throws {
        let (base, root, checkout, defaults, store) = try fixture()
        defer { try? FileManager.default.removeItem(at: base); defaults.removePersistentDomain(forName: base.lastPathComponent) }
        let runner = WorktreeSetupRunner(defaults: defaults, logsDirectory: base.appendingPathComponent("logs"), enabled: { true })
        try write("echo failed; exit 7", checkout: checkout)
        var releases = 0
        runner.run(after: result(root, checkout), store: store) { releases += 1 }
        try await eventually { runner.state(for: checkout)?.phase == .failed }
        XCTAssertEqual(releases, 0)
        XCTAssertTrue(runner.state(for: checkout)?.detail.contains("7") == true)
        try write("echo fixed", checkout: checkout)
        runner.retry(checkout, store: store)
        try await eventually { runner.state(for: checkout)?.phase == .ready }
        XCTAssertEqual(releases, 1)
    }

    func testExplicitImmediateStartupStillRecordsCompletion() async throws {
        let (base, root, checkout, defaults, store) = try fixture()
        defer { try? FileManager.default.removeItem(at: base); defaults.removePersistentDomain(forName: base.lastPathComponent) }
        let runner = WorktreeSetupRunner(defaults: defaults, logsDirectory: base.appendingPathComponent("logs"), enabled: { true })
        try write("sleep 0.2; touch ready", checkout: checkout, wait: false)
        var releases = 0
        runner.run(after: result(root, checkout), store: store) {
            XCTAssertEqual(runner.state(for: checkout)?.phase, .running); releases += 1
        }
        try await eventually { runner.state(for: checkout)?.phase == .ready }
        XCTAssertEqual(releases, 1)
    }
}
