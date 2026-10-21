import XCTest
@testable import Octet

@MainActor
final class ProjectJobLifecycleTests: XCTestCase {
    func testOccurrenceIsSavedBeforeDispatchOverlapBlockedAndRestartPausesPendingLaunch() async throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: folder) }
        let file = folder.appendingPathComponent("jobs.json")
        let store = SessionStore(client: Octet.EngineClient(socketPath: folder.appendingPathComponent("unused.sock").path))
        var dispatched = 0
        let center = ProjectJobCenter(file: file, allowed: { true }, connectionReady: { true }) { _, _ in
            dispatched += 1
            let json = try? JSONSerialization.jsonObject(with: Data(contentsOf: file)) as? [String: Any]
            XCTAssertEqual((json?["runs"] as? [[String: Any]])?.count, 1, "Claim must be persisted before execution")
        }
        center.start(store: store)
        let now = Date()
        let job = Octet.ProjectJob(root: folder.path, name: "Check", prompt: "Review", provider: "codex", cron: "* * * * *", timeZone: "UTC", nextRun: now.addingTimeInterval(-120))
        try center.upsert(job)
        center.tick(now: now)
        for _ in 0..<100 where dispatched == 0 { try await Task.sleep(nanoseconds: 10_000_000) }
        XCTAssertEqual(dispatched, 1)
        XCTAssertGreaterThan(try XCTUnwrap(center.jobs.first?.nextRun), now)
        center.run(job.id)
        XCTAssertEqual(dispatched, 1, "Active job must not overlap")
        let restored = ProjectJobCenter(file: file, allowed: { true })
        restored.start(store: store)
        XCTAssertEqual(restored.runs.first?.status, .interrupted)
        XCTAssertEqual(restored.jobs.first?.enabled, false)
        XCTAssertTrue(restored.runs.first?.detail.contains("Inspect workspace") == true)
    }

    func testAcknowledgingRunPausesScheduleRatherThanStartingAnotherAgent() throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: folder) }
        let store = SessionStore(client: Octet.EngineClient(socketPath: folder.appendingPathComponent("unused.sock").path))
        let center = ProjectJobCenter(file: folder.appendingPathComponent("jobs.json"), allowed: { true }, execute: { _, _ in })
        center.start(store: store)
        let job = Octet.ProjectJob(root: folder.path, name: "Check", prompt: "Review", provider: "codex", cron: "0 9 * * *", timeZone: "UTC", nextRun: Date())
        try center.upsert(job)
        center.run(job.id)
        center.acknowledge(try XCTUnwrap(center.runs.first?.id))
        XCTAssertEqual(center.jobs.first?.enabled, false)
        XCTAssertEqual(center.runs.first?.status, .interrupted)
    }
}
