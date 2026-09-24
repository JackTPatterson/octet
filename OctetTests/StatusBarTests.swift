import XCTest

final class StatusBarOrderTests: XCTestCase {
    private func item(_ id: String, on: Bool) -> StatusItemDescriptor {
        StatusItemDescriptor(id: id, name: id, summary: "", sample: id, enabledByDefault: on)
    }

    func testUntouchedBarShowsEveryDefaultChip() {
        let available = [item("a", on: true), item("b", on: false), item("c", on: true)]
        XCTAssertEqual(StatusBarItems.resolve(saved: [], customized: false, seen: [], available: available), ["a", "c"])
    }

    func testArrangedBarKeepsItsOrderAndDropsChipsThatAreGone() {
        let available = [item("a", on: true), item("b", on: false), item("c", on: true)]
        XCTAssertEqual(StatusBarItems.resolve(saved: ["c", "gone", "b"], customized: true, seen: ["a", "b", "c", "gone"],
                                              available: available), ["c", "b"])
    }

    func testAChipArrivingLaterStartsOnButARemovedOneStaysOff() {
        let available = [item("a", on: true), item("new", on: true), item("off", on: false)]
        // "a" was seen and removed; "new" arrives with a plugin.
        XCTAssertEqual(StatusBarItems.resolve(saved: [], customized: true, seen: ["a"], available: available), ["new"])
    }

    func testMarkerFilesAreFoundUpToTheRootButNotAbove() {
        let files: Set<String> = ["/repo/web/.nvmrc", "/.nvmrc"]
        let exists = { files.contains($0) }
        XCTAssertTrue(StatusBarItems.hasMarker([".nvmrc"], from: "/repo/web/src", root: "/repo", exists: exists))
        XCTAssertFalse(StatusBarItems.hasMarker([".nvmrc"], from: "/repo/api", root: "/repo", exists: exists))
        XCTAssertTrue(StatusBarItems.hasMarker([], from: "/anywhere", root: nil, exists: exists))
    }
}

final class StatusItemOutputTests: XCTestCase {
    func testFirstLineIsTheTextAndLaterLinesSetTheRest() {
        let output = StatusItemOutput.parse("prod/web\ntone: danger\nhelp: kubectl context prod\nurl: https://example.com\n")
        XCTAssertEqual(output?.text, "prod/web")
        XCTAssertEqual(output?.tone, .danger)
        XCTAssertEqual(output?.help, "kubectl context prod")
        XCTAssertEqual(output?.url, URL(string: "https://example.com"))
    }

    func testNothingPrintedHidesTheChipAndOnlyWebLinksOpen() {
        XCTAssertNil(StatusItemOutput.parse(""))
        XCTAssertNil(StatusItemOutput.parse("\n  \n"))
        XCTAssertNil(StatusItemOutput.parse("x\nurl: file:///etc/passwd")?.url)
        XCTAssertEqual(StatusItemOutput.parse("x\ntone: sparkly")?.tone, .normal)
    }
}

final class GitOperationTests: XCTestCase {
    func testRebaseShowsItsStep() {
        let files: [String: String] = ["/g/rebase-merge/msgnum": "3\n", "/g/rebase-merge/end": "7\n"]
        let operation = GitOperation.read(gitDir: "/g", exists: { $0 == "/g/rebase-merge" || files[$0] != nil },
                                          read: { files[$0] })
        XCTAssertEqual(operation.label, "REBASING 3/7")
    }

    func testMergeWithConflicts() {
        var operation = GitOperation.read(gitDir: "/g", exists: { $0 == "/g/MERGE_HEAD" }, read: { _ in nil })
        operation.conflicts = 2
        XCTAssertEqual(operation.label, "MERGING · 2 conflicts")
        XCTAssertTrue(GitOperation.read(gitDir: "/g", exists: { _ in false }, read: { _ in nil }).isEmpty)
    }
}

final class StatusChipsPluginTests: XCTestCase {
    func testTheBundledPluginLoadsWithEveryIconAndScript() throws {
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("Plugins").path
        let found = OctetPlugins.discover(bundled: root, user: "/nonexistent")
        XCTAssertEqual(found.problems, [])
        let plugin = try XCTUnwrap(found.plugins.first { $0.id == "status-chips" })
        XCTAssertGreaterThan(plugin.manifest.contributes.statusItems.count, 10)
        for item in plugin.manifest.contributes.statusItems {
            if let icon = item.icon {
                XCTAssertTrue(FileManager.default.fileExists(atPath: plugin.directory + "/" + icon), item.id)
            }
            let script = item.run.components(separatedBy: "\"$OCTET_PLUGIN_DIR/").last?.replacingOccurrences(of: "\"", with: "")
            XCTAssertTrue(FileManager.default.fileExists(atPath: plugin.directory + "/" + (script ?? "")), item.id)
        }
    }

    func testStatusItemsNeedAnIdAndSomethingToRun() {
        var manifest = OctetPluginManifest(id: "x", name: "X")
        manifest.contributes.statusItems = [.init(id: "Bad Id", name: "B", run: "true")]
        XCTAssertNotNil(OctetPlugins.validate(manifest))
        manifest.contributes.statusItems = [.init(id: "ok", name: "B", run: " ")]
        XCTAssertNotNil(OctetPlugins.validate(manifest))
        manifest.contributes.statusItems = [.init(id: "ok", name: "B", run: "echo hi")]
        XCTAssertNil(OctetPlugins.validate(manifest))
    }
}
