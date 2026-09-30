import XCTest

final class PluginPanelTests: XCTestCase {
    private func manifest(_ panels: String) throws -> OctetPluginManifest {
        try JSONDecoder().decode(OctetPluginManifest.self, from: Data(#"{"id": "p", "name": "P", "contributes": {"panels": \#(panels)}}"#.utf8))
    }

    func testPanelsReadFromAManifest() throws {
        let plugin = try manifest(#"[{"id": "containers", "title": "Containers", "icon": "icons/docker.svg", "whenFiles": ["compose.yaml"], "run": "sh panel.sh", "act": "sh act.sh", "refreshSeconds": 5}]"#)
        XCTAssertNil(OctetPlugins.validate(plugin))
        let panel = try XCTUnwrap(plugin.contributes.panels.first)
        XCTAssertEqual(panel.run, "sh panel.sh")
        XCTAssertEqual(panel.act, "sh act.sh")
        XCTAssertEqual(panel.whenFiles, ["compose.yaml"])
        // A panel with nothing to act on is fine; a manifest without panels has none.
        XCTAssertNil(OctetPlugins.validate(try manifest(#"[{"id": "a", "title": "A", "run": "true"}]"#)))
        XCTAssertEqual(try manifest("[]").contributes.panels, [])
    }

    func testBadPanelsAreRefused() throws {
        XCTAssertNotNil(OctetPlugins.validate(try manifest(#"[{"id": "a", "title": " ", "run": "true"}]"#)))
        XCTAssertNotNil(OctetPlugins.validate(try manifest(#"[{"id": "Bad Id", "title": "A", "run": "true"}]"#)))
        XCTAssertNotNil(OctetPlugins.validate(try manifest(#"[{"id": "a", "title": "A", "run": "true"}, {"id": "a", "title": "B", "run": "true"}]"#)))
        XCTAssertNotNil(OctetPlugins.validate(try manifest(#"[{"id": "a", "title": "A", "run": "true", "act": {"windows": ""}}]"#)))
    }

    func testOutputIsAPanel() throws {
        let panel = try XCTUnwrap(PluginPanel.parse(#"""
        {"badge": "1/2", "tone": "warning",
         "rows": [{"id": "web", "title": "web", "detail": "Up 3 min", "tone": "success", "url": "http://localhost:8080",
                   "actions": [{"id": "stop", "title": "Stop", "symbol": "stop.fill"}]},
                  {"id": "worker", "title": "worker", "tone": "sparkly", "url": "file:///etc/passwd"}],
         "actions": [{"id": "down", "title": "Down", "confirm": "Remove them?"}]}
        """#))
        XCTAssertEqual(panel.badge, "1/2")
        XCTAssertEqual(panel.tone, .warning)
        XCTAssertEqual(panel.rows.map(\.id), ["web", "worker"])
        XCTAssertEqual(panel.rows[0].link?.absoluteString, "http://localhost:8080")
        XCTAssertEqual(panel.rows[0].actions.first?.symbol, "stop.fill")
        // An unknown tone is none, and only web links open.
        XCTAssertNil(panel.rows[1].tone)
        XCTAssertNil(panel.rows[1].link)
        XCTAssertEqual(panel.actions.first?.confirm, "Remove them?")
    }

    func testNothingHidesTheButton() {
        XCTAssertNil(PluginPanel.parse(""))
        XCTAssertNil(PluginPanel.parse("  \n"))
        XCTAssertNil(PluginPanel.parse("not json"))
        XCTAssertEqual(PluginPanel.parse("{}"), PluginPanel())
    }

    func testTheContainersPluginLoads() throws {
        let root = try TestPlugins.pluginsPath()
        let found = OctetPlugins.discover(bundled: root, user: "/nonexistent")
        XCTAssertEqual(found.problems, [])
        guard let plugin = found.plugins.first(where: { $0.id == "containers" }) else {
            throw XCTSkip("The plugins checkout predates the containers plugin")
        }
        XCTAssertEqual(plugin.manifest.contributes.panels.map(\.title), ["Containers"])
        XCTAssertTrue(FileManager.default.fileExists(atPath: plugin.directory + "/scripts/panel.sh"))
    }
}
