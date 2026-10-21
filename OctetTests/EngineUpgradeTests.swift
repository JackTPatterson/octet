import XCTest
@testable import Octet

final class EngineUpgradeTests: XCTestCase {
    /// What the engine Octet shipped before pane streaming says to the probe.
    func testAnOlderEngineIsOutdated() {
        let message = "invalid request: unknown variant `pane.stream`, expected one of `ping`, `server.stop`, `server.live_handoff`"
        XCTAssertTrue(EngineUpgrade.isOutdated(code: "invalid_request", message: message))
    }

    /// A current engine knows the call and only lacks the pane.
    func testACurrentEngineIsNot() {
        XCTAssertFalse(EngineUpgrade.isOutdated(code: "pane_not_found", message: "pane octet-upgrade-probe not found"))
    }

    /// Other bad requests aren't a reason to replace the server.
    func testOtherInvalidRequestsAreNot() {
        XCTAssertFalse(EngineUpgrade.isOutdated(code: "invalid_request", message: "invalid request: missing field `pane_id`"))
        XCTAssertFalse(EngineUpgrade.isOutdated(code: "invalid_request", message: "invalid request: unknown variant `tab.set_viewport`"))
    }

    func testHandoffNamesTheBundledEngine() {
        XCTAssertEqual(EngineUpgrade.handoffParams(enginePath: "/Applications/Octet.app/Contents/MacOS/octet-engine")["import_exe"] as? String,
                       "/Applications/Octet.app/Contents/MacOS/octet-engine")
    }
}
