import XCTest

final class KeepAwakeTests: XCTestCase {
    func testHoldsOnlyWhileSomeAgentIsWorking() {
        XCTAssertNil(KeepAwake.reason(mode: .always, statuses: [], onBattery: false))
        XCTAssertNil(KeepAwake.reason(mode: .always, statuses: [.idle, .done, .blocked, .unknown], onBattery: false))
        XCTAssertEqual(KeepAwake.reason(mode: .always, statuses: [.idle, .working], onBattery: false),
                       "An agent is working in Octet")
        XCTAssertEqual(KeepAwake.reason(mode: .always, statuses: [.working, .working, .blocked], onBattery: false),
                       "2 agents are working in Octet")
    }

    func testAnAgentWaitingOnYouDoesntKeepTheMacUp() {
        // Blocked means it needs a person, and nobody is at the Mac.
        XCTAssertNil(KeepAwake.reason(mode: .always, statuses: [.blocked], onBattery: false))
    }

    func testPluggedInLetsABatteryMacSleep() {
        XCTAssertNotNil(KeepAwake.reason(mode: .pluggedIn, statuses: [.working], onBattery: false))
        XCTAssertNil(KeepAwake.reason(mode: .pluggedIn, statuses: [.working], onBattery: true))
        XCTAssertNotNil(KeepAwake.reason(mode: .always, statuses: [.working], onBattery: true))
    }

    func testOffNeverHolds() {
        XCTAssertNil(KeepAwake.reason(mode: .off, statuses: [.working], onBattery: false))
    }

    func testModesRoundTripThroughTheirStoredNames() throws {
        for mode in KeepAwake.Mode.allCases {
            let data = try JSONEncoder().encode(mode)
            XCTAssertEqual(try JSONDecoder().decode(KeepAwake.Mode.self, from: data), mode)
        }
        XCTAssertEqual(try JSONDecoder().decode(KeepAwake.Mode.self, from: Data("\"plugged_in\"".utf8)), .pluggedIn)
    }
}
