import XCTest

final class CronDescriptionTests: XCTestCase {
    func testCommonSchedulesReadAsWords() {
        XCTAssertEqual(CronDescription.describe("0 9 * * *"), "Every day at 9:00")
        XCTAssertEqual(CronDescription.describe("30 17 * * 1-5"), "Weekdays at 17:30")
        XCTAssertEqual(CronDescription.describe("0 9 * * 1"), "Mondays at 9:00")
        XCTAssertEqual(CronDescription.describe("0 9 * * 0,6"), "Weekends at 9:00")
        XCTAssertEqual(CronDescription.describe("0 9 * * 5,1,3"), "Mondays, Wednesdays and Fridays at 9:00")
        XCTAssertEqual(CronDescription.describe("0 9,17 * * *"), "Every day at 9:00 and 17:00")
        XCTAssertEqual(CronDescription.describe("0 8 1 * *"), "On the 1st of every month at 8:00")
        XCTAssertEqual(CronDescription.describe("0 8 22 * *"), "On the 22nd of every month at 8:00")
    }

    func testHourlyAndSubHourly() {
        XCTAssertEqual(CronDescription.describe("0 * * * *"), "Every hour")
        XCTAssertEqual(CronDescription.describe("5 * * * *"), "Every hour at :05")
        XCTAssertEqual(CronDescription.describe("*/15 * * * *"), "Every 15 minutes")
        XCTAssertEqual(CronDescription.describe("* * * * *"), "Every minute")
    }

    func testSundayAsSevenAndUnusualShapesFallBack() {
        XCTAssertEqual(CronDescription.describe("0 9 * * 7"), "Sundays at 9:00")
        XCTAssertNil(CronDescription.describe("0 9 * 6 *"))
        XCTAssertNil(CronDescription.describe("0 */2 * * *"))
        XCTAssertNil(CronDescription.describe("0 9 1 * 1"))
        XCTAssertNil(CronDescription.describe("not cron"))
    }
}
