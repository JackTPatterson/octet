import XCTest
@testable import Octet

final class SettingsSearchTests: XCTestCase {
    func testEverySectionCanBeFoundBySearch() {
        let searched = Set(SettingsSearchIndex.entries.map(\.section))
        for section in SettingsView.Section.allCases {
            XCTAssertTrue(searched.contains(section), "\(section.title) has nothing in the search index")
        }
    }

    func testNotificationSettingsLiveUnderNotifications() {
        let sections = Set(SettingsSearchIndex.search("notification").map(\.section))
        XCTAssertTrue(sections.contains(.notifications))
        XCTAssertEqual(SettingsSearchIndex.search("bell").first?.section, .notifications)
        XCTAssertEqual(SettingsSearchIndex.search("jira").first?.section, .integrations)
    }

    func testResultCountSaysHowManyAndWhere() {
        let one = [SettingsSearchEntry(.general, "Shell")]
        XCTAssertEqual(SettingsView.resultCount(one), "1 setting")
        let spread = one + [SettingsSearchEntry(.notifications, "Play sounds"), SettingsSearchEntry(.notifications, "Terminal bell")]
        XCTAssertEqual(SettingsView.resultCount(spread), "3 settings in 2 sections")
    }

    func testEveryEntryIsUnique() {
        let ids = SettingsSearchIndex.entries.map(\.id)
        XCTAssertEqual(ids.count, Set(ids).count, "Duplicate search entries: \(ids.filter { id in ids.filter { $0 == id }.count > 1 })")
    }
}
