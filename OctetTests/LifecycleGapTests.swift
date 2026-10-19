import XCTest
@testable import Octet

final class LifecycleGapTests: XCTestCase {
    func testIssueLinkBelongsToWorktreeAndResolvesFromSubdirectory() throws {
        let base = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: base) }
        try FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
        let git = Git()
        try git.run(["init", "-q"], in: base.path)
        try git.run(["-c", "user.name=Test", "-c", "user.email=test@example.com", "commit", "--allow-empty", "-qm", "base"], in: base.path)
        let wt = base.appendingPathComponent("linked")
        try git.run(["worktree", "add", "-qb", "issue", wt.path], in: base.path)
        let sub = wt.appendingPathComponent("sub")
        try FileManager.default.createDirectory(at: sub, withIntermediateDirectories: true)
        let link = WorkspaceIssueLink(tracker: "Linear", connectionId: "work", issueId: "123", key: "ENG-7", title: "Fix", url: nil)
        try link.save(in: wt.path)
        XCTAssertEqual(try WorkspaceIssueLink.read(in: sub.path), link)
        XCTAssertNil(try WorkspaceIssueLink.read(in: base.path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: wt.appendingPathComponent("octet-issue.json").path))
    }

    func testDraftRetentionOmitsScreenshotAndPreservesIDs() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let file = BrowserDrafts.file(key: "workspace/one", directory: directory)
        let context = BrowserElementContext(url: "https://example.test", title: "Page", selector: "#save", html: "<button>Save</button>", text: "Save", styles: [:], rect: .init(x: 0, y: 0, width: 10, height: 20, viewportWidth: 390, viewportHeight: 844))
        let item = BrowserAnnotation(context: context, note: "Change color", screenshot: Data("screenshot-secret".utf8))
        try BrowserDrafts.save([item], to: file, projectDirectory: "/repo/wt/sub")
        XCTAssertTrue(BrowserDrafts.retained(in: "/repo/wt", directory: directory))
        XCTAssertFalse(BrowserDrafts.retained(in: "/repo/other", directory: directory))
        let restored = try BrowserDrafts.load(file)
        XCTAssertEqual(restored.first?.id, item.id)
        XCTAssertEqual(restored.first?.note, "Change color")
        XCTAssertFalse(try String(contentsOf: file, encoding: .utf8).contains("screenshot"))
        try BrowserDrafts.save([], to: file)
        XCTAssertEqual(try BrowserDrafts.load(file), [])
    }

    func testCronRangesStepsDayRulesAndDST() throws {
        let parse = ISO8601DateFormatter()
        let friday = parse.date(from: "2026-10-16T14:00:00Z")!
        let weekdays = try CronSchedule("0 9 * * 1-5", timeZone: "America/New_York")
        XCTAssertEqual(try weekdays.next(after: friday), parse.date(from: "2026-10-19T13:00:00Z"))
        let skippedHour = try CronSchedule("30 2 * * *", timeZone: "America/New_York")
        XCTAssertEqual(try skippedHour.next(after: parse.date(from: "2026-03-08T06:59:00Z")!), parse.date(from: "2026-03-09T06:30:00Z"))
        let either = try CronSchedule("*/15 9 1 * 1", timeZone: "UTC")
        XCTAssertTrue(either.matches(parse.date(from: "2026-10-19T09:15:00Z")!))
        XCTAssertTrue(either.matches(parse.date(from: "2026-11-01T09:30:00Z")!))
        for cron in ["* * * *", "*/0 * * * *", "60 * * * *", "0 9 0 * *", "0 9 * * 8", "0 9 * * 5-1"] {
            XCTAssertThrowsError(try CronSchedule(cron, timeZone: "UTC"))
        }
        XCTAssertThrowsError(try CronSchedule("0 9 * * *", timeZone: "Not/AZone"))
    }

    func testCleanupBlockersOverrideCleanMergedState() {
        var row = WorktreeCleanup.Worktree(path: "/repo/wt", branch: "done", isMain: false, merged: true, dirty: false)
        XCTAssertTrue(row.removable)
        row.blockers = ["Unsaved editor changes"]
        XCTAssertFalse(row.removable)
    }

    func testArchiveSuccessFailureAndTimeoutNeverDeletesCheckout() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        var config = Octet.ProjectConfiguration()
        config.archive = "printf success > archived"
        try await ArchiveHook.run(config, checkout: directory.path, root: directory.path)
        XCTAssertEqual(try String(contentsOf: directory.appendingPathComponent("archived"), encoding: .utf8), "success")
        config.archive = "exit 7"
        do { try await ArchiveHook.run(config, checkout: directory.path, root: directory.path); XCTFail("Expected failure") }
        catch { XCTAssertTrue(error.localizedDescription.contains("7")) }
        config.archive = "trap 'exit 0' TERM; sleep 10; touch should-not-exist"
        config.archiveTimeoutSeconds = 1
        do { try await ArchiveHook.run(config, checkout: directory.path, root: directory.path); XCTFail("Expected timeout") }
        catch { XCTAssertTrue(error.localizedDescription.contains("timed out")) }
        XCTAssertTrue(FileManager.default.fileExists(atPath: directory.path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: directory.appendingPathComponent("should-not-exist").path))
    }
}
