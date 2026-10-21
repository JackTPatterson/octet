import XCTest

final class ShellRecoveryInPlaceTests: XCTestCase {
    func testAJournalFromBeforePaneIdsStillLoads() throws {
        let json = #"{"lastObserved":"2026-10-01T10:00:00Z","records":[{"terminalId":"t1","workspaceLabel":"repo","tabLabel":"dev","cwd":"/repo","command":"npm run dev","firstSeen":"2026-10-01T09:00:00Z","lastSeen":"2026-10-01T10:00:00Z"}]}"#
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let journal = try decoder.decode(ShellSessionJournal.self, from: Data(json.utf8))
        XCTAssertEqual(journal.records.first?.terminalId, "t1")
        XCTAssertNil(journal.records.first?.paneId)
    }

    func testTheLineForARestoredPanePrintsWhatItLastShowed() {
        let record = ShellSessionRecord(terminalId: "t1", workspaceLabel: "repo", tabLabel: "dev", cwd: "/repo",
                                        command: "npm run dev", firstSeen: Date(), lastSeen: Date(), paneId: "w1:p2")
        let line = ShellRecovery.inPlaceLine(record, dump: URL(fileURLWithPath: "/tmp/t 1.ansi"))
        XCTAssertTrue(line.hasPrefix(" clear; cat '/tmp/t 1.ansi'"))
        XCTAssertTrue(line.contains("'npm run dev'"))
        // Typed into a shell at a prompt: no exec, the shell stays.
        XCTAssertFalse(line.contains("exec "))
    }
}
