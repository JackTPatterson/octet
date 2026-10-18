import XCTest
@testable import Octet

@MainActor
final class PlaneExtensionTests: XCTestCase {
    private let keys = ["octet.planes", "octet.activePlane", "octet.splitPlanes", "octet.splitSideBySide", "octet.sidePanelVisible"]
    private var saved: [String: Any] = [:]

    override func setUp() {
        super.setUp()
        for key in keys {
            saved[key] = UserDefaults.standard.object(forKey: key)
            UserDefaults.standard.removeObject(forKey: key)
        }
    }

    override func tearDown() {
        for key in keys {
            if let value = saved[key] { UserDefaults.standard.set(value, forKey: key) }
            else { UserDefaults.standard.removeObject(forKey: key) }
        }
        super.tearDown()
    }

    func testOriginalLauncherAndUniqueKeys() throws {
        XCTAssertEqual(PlaneKind.starterKinds.map(\.rawValue), ["overview", "diff", "files", "git", "pullRequest", "pullRequests", "terminal", "browser", "device"])
        XCTAssertEqual(Set(PlaneKind.allCases.map(\.key)).count, PlaneKind.allCases.count)
        for kind in [PlaneKind.ci, .containers, .tickets] {
            let plane = Plane.make(kind)
            XCTAssertEqual(try JSONDecoder().decode(Plane.self, from: JSONEncoder().encode(plane)), plane)
        }
    }

    func testSplitUsesBundledIconsax() {
        XCTAssertEqual(OctetIcon.map["rectangle.split.1x2"]?.asset, "row-vertical")
        XCTAssertEqual(OctetIcon.map["rectangle.split.2x1"]?.asset, "row-horizontal")
        XCTAssertNil(OctetIcon.map["rectangle.split.1x2"]?.symbol)
        XCTAssertNil(OctetIcon.map["rectangle.split.2x1"]?.symbol)
    }

    func testMultipleSplitsPersist() {
        let suite = "panel-tests-" + UUID().uuidString
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        let ui = UIState()
        ui.panelDefaults = defaults
        ui.activateWorkspacePanel("a")
        ui.showPlane(.git)
        ui.splitPlane(.ci)
        ui.splitPlane(.containers)
        XCTAssertEqual(ui.visiblePlaneIds, ["git", "ci", "containers"])
        let restored = UIState()
        restored.panelDefaults = defaults
        restored.activateWorkspacePanel("a")
        XCTAssertEqual(restored.visiblePlaneIds, ui.visiblePlaneIds)
        XCTAssertTrue(ui.showing(.git))
        XCTAssertTrue(ui.showing(.ci))
    }

    func testWorkspacePanelsAreIsolatedAndRestored() {
        let suite = "panel-tests-" + UUID().uuidString
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        let ui = UIState()
        ui.panelDefaults = defaults
        ui.showPlane(.containers)
        ui.activateWorkspacePanel("a")
        XCTAssertEqual(ui.activePlane?.kind, .containers, "Migrate the original panel once")
        ui.splitPlane(.tickets)
        ui.splitSideBySide = true
        ui.planeSplitWeights = ["containers": 2, "tickets": 1]
        ui.sidePanelWidth = 555
        ui.additionalPlaneShortcuts = "containers,tickets"
        ui.setPanelSection(.todos, open: false)
        ui.activateWorkspacePanel("b")
        XCTAssertEqual(ui.planes, Plane.defaults)
        XCTAssertFalse(ui.sidePanelVisible)
        XCTAssertTrue(ui.additionalPlaneShortcuts.isEmpty)
        XCTAssertTrue(ui.panelSectionIsOpen(.todos))
        ui.showPlane(.ci)
        ui.closePlane("ci")
        ui.activateWorkspacePanel("a")
        XCTAssertEqual(ui.visiblePlaneIds, ["containers", "tickets"])
        XCTAssertEqual(ui.planeSplitWeights["containers"], 2)
        XCTAssertEqual(ui.sidePanelWidth, 555)
        XCTAssertEqual(ui.additionalPlaneShortcuts, "containers,tickets")
        XCTAssertFalse(ui.panelSectionIsOpen(.todos))
        XCTAssertTrue(ui.closedPlanes.isEmpty)
        let restored = UIState()
        restored.panelDefaults = defaults
        restored.activateWorkspacePanel("a")
        XCTAssertEqual(restored.visiblePlaneIds, ui.visiblePlaneIds)
        restored.activateWorkspacePanel("b")
        XCTAssertFalse(restored.planes.contains { $0.kind == .ci })
        ui.activateWorkspacePanel("b")
        XCTAssertEqual(ui.closedPlanes.last?.kind, .ci)
        ui.closePlanes { _ in true }
        restored.activateWorkspacePanel("a")
        restored.activateWorkspacePanel("b")
        XCTAssertTrue(restored.planes.isEmpty, "An empty launcher is also workspace state")
    }

    func testSelectionReplacesOnlyFocusedSplit() {
        let ui = UIState()
        ui.showPlane(.git)
        ui.splitPlane(.ci)
        ui.activePlaneId = "git"
        XCTAssertEqual(ui.visiblePlaneIds, ["git", "ci"])
        ui.showPlane(.tickets)
        XCTAssertEqual(ui.visiblePlaneIds, ["tickets", "ci"])
    }

    func testRemovingSplitPreservesTabAndClosingPreservesRemainingSplits() {
        let ui = UIState()
        ui.showPlane(.git)
        ui.splitPlane(.ci)
        ui.splitPlane(.containers)
        ui.closePlane("containers")
        XCTAssertEqual(ui.visiblePlaneIds, ["git", "ci"])
        ui.removePlaneFromSplit("ci")
        XCTAssertEqual(ui.visiblePlaneIds, ["git"])
        XCTAssertTrue(ui.planes.contains { $0.kind == .ci })
        XCTAssertTrue(ui.splitPlaneIds.isEmpty)
        ui.closePlanes { _ in true }
        XCTAssertFalse(ui.sidePanelVisible, "Preserve the existing close-last-pane behavior")
    }

    func testExistingTerminalCanSplitWithoutCreatingAnother() {
        let ui = UIState()
        ui.showPlane(.terminal)
        let terminal = ui.activePlane!.id
        ui.showPlane(.git)
        let count = ui.planes.count
        ui.splitExistingPlane(terminal)
        XCTAssertEqual(ui.visiblePlaneIds, ["git", terminal])
        XCTAssertEqual(ui.planes.count, count)
    }

    func testSplitSizingPreservesMinimumAndTotal() {
        let lengths = PlaneSplitSizing.lengths(ids: ["a", "b", "c"], weights: ["a": 2, "b": 0, "c": 1], extent: 900, minimum: 140)
        XCTAssertEqual(lengths.reduce(0, +), 900, accuracy: 0.001)
        XCTAssertTrue(lengths.allSatisfy { $0 >= 140 })
        XCTAssertEqual(lengths[1], 140)
        XCTAssertEqual(PlaneSplitSizing.lengths(ids: ["a"], weights: [:], extent: 420, minimum: 240), [420])
    }

    func testCIStatusAndContainerJSONLines() throws {
        let output = #"[{"databaseId":42,"displayTitle":"Build","workflowName":"CI","headBranch":"main","status":"in_progress","conclusion":"","url":"https://github.com/a/b/actions/runs/42","event":"push","createdAt":"2026-10-18T00:00:00Z"}]"#
        let runs = try OperationItem.parse(output, ci: true)
        XCTAssertEqual(runs.first?.status, "in_progress")
        XCTAssertEqual(runs.first?.id, "42")
        let containers = try OperationItem.parse("{\"ID\":\"a\",\"Names\":\"api\",\"State\":\"running\"}\n{\"ID\":\"b\",\"Names\":\"db\",\"State\":\"exited\"}", ci: false)
        XCTAssertEqual(containers.map(\.status), ["running", "exited"])
        XCTAssertTrue(try OperationItem.parse("", ci: false).isEmpty)
        XCTAssertThrowsError(try OperationItem.parse("not json", ci: true))
    }

    func testBoardURLsRejectUnsafeOrCredentialBearingAddresses() {
        XCTAssertNotNil(TicketsPlane.boardURL(" https://linear.app/example/project/abc \n"))
        XCTAssertNil(TicketsPlane.boardURL("file:///etc/passwd"))
        XCTAssertNil(TicketsPlane.boardURL("https://user:secret@example.com/project"))
        XCTAssertNil(TicketsPlane.boardURL("javascript:alert(1)"))
    }

    func testContainerOutputAllowsNestedPlatformAndAdditionalFields() throws {
        let output = #"{"ID":"5308e11a427a","Names":"postgres","Image":"postgres:17-alpine","State":"exited","Status":"Exited (255) About a minute ago","Ports":"0.0.0.0:55432->5432/tcp","Platform":{"architecture":"arm64","os":"linux","variant":"v8"},"HealthStatus":"starting"}"#
        let items = try OperationItem.parse(output, ci: false)
        XCTAssertEqual(items.count, 1)
        XCTAssertEqual(items.first?.id, "5308e11a427a")
        XCTAssertEqual(items.first?.title, "postgres")
        XCTAssertEqual(items.first?.subtitle, "postgres:17-alpine")
        XCTAssertEqual(items.first?.status, "exited")
        XCTAssertTrue(items.first?.detail.contains("55432->5432/tcp") == true)
    }
}
