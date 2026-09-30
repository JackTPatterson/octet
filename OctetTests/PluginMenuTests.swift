import XCTest

final class PluginMenuTests: XCTestCase {
    private func manifest(_ items: String) throws -> OctetPluginManifest {
        try JSONDecoder().decode(OctetPluginManifest.self, from: Data(#"{"id": "p", "name": "P", "contributes": {"menuItems": \#(items)}}"#.utf8))
    }

    func testMenuItemsReadFromAManifest() throws {
        let plugin = try manifest(#"[{"id": "start", "title": "Start Dev Server", "in": ["workspace"], "whenFiles": ["package.json"], "run": "sh detect.sh"}]"#)
        XCTAssertNil(OctetPlugins.validate(plugin))
        let item = try XCTUnwrap(plugin.contributes.menuItems.first)
        XCTAssertTrue(item.isIn(.workspace))
        XCTAssertFalse(item.isIn(.tab))
        XCTAssertEqual(item.run, "sh detect.sh")
        // Both menus unless it says.
        let both = try manifest(#"[{"id": "a", "title": "A", "run": "true"}]"#).contributes.menuItems[0]
        XCTAssertTrue(both.isIn(.tab) && both.isIn(.workspace))
    }

    func testBadMenuItemsAreRefused() throws {
        XCTAssertNotNil(OctetPlugins.validate(try manifest(#"[{"id": "a", "title": " ", "run": "true"}]"#)))
        XCTAssertNotNil(OctetPlugins.validate(try manifest(#"[{"id": "Bad Id", "title": "A", "run": "true"}]"#)))
        XCTAssertNotNil(OctetPlugins.validate(try manifest(#"[{"id": "a", "title": "A", "run": "true"}, {"id": "a", "title": "B", "run": "true"}]"#)))
        XCTAssertNotNil(OctetPlugins.validate(try manifest(#"[{"id": "a", "title": "A", "run": {"windows": ""}}]"#)))
    }

    func testOutputIsACommandThenDetails() {
        XCTAssertEqual(PluginMenuOutput.parse("pnpm dev\nlabel: web · dev\ncwd: /code/web\n"),
                       PluginMenuOutput(command: "pnpm dev", label: "web · dev", cwd: "/code/web"))
        // A colon inside the command doesn't make it a detail.
        XCTAssertEqual(PluginMenuOutput.parse("bin/rails server -b 0.0.0.0:3000").command, "bin/rails server -b 0.0.0.0:3000")
        let nothing = PluginMenuOutput.parse("message: No dev server found\n")
        XCTAssertNil(nothing.command)
        XCTAssertEqual(nothing.message, "No dev server found")
        XCTAssertNil(PluginMenuOutput.parse("").command)
    }

    func testTheDevServerPluginLoads() throws {
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("Registry/plugins").path
        let found = OctetPlugins.discover(bundled: root, user: "/nonexistent")
        XCTAssertEqual(found.problems, [])
        let plugin = try XCTUnwrap(found.plugins.first { $0.id == "dev-server" })
        XCTAssertEqual(plugin.manifest.contributes.menuItems.map(\.title), ["Start Dev Server"])
        XCTAssertTrue(FileManager.default.fileExists(atPath: plugin.directory + "/detect.sh"))
    }
}
