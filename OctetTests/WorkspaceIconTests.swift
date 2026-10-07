import XCTest

final class WorkspaceIconTests: XCTestCase {
    func testAnIconMustBeAnImageInsideTheWorkspace() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("octet-icon-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir.appendingPathComponent("public"), withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let icon = dir.appendingPathComponent("public/favicon.png")
        try Data([0x89]).write(to: icon)
        try Data("x".utf8).write(to: dir.appendingPathComponent("notes.txt"))
        let root = dir.path
        let real = icon.resolvingSymlinksInPath().path

        XCTAssertEqual(WorkspaceIconPath.resolve("public/favicon.png\n", in: root), real)
        XCTAssertEqual(WorkspaceIconPath.resolve(icon.path, in: root), real)
        // Outside the folder, not an image, missing, or nothing printed.
        XCTAssertNil(WorkspaceIconPath.resolve("../../etc/hosts.png", in: root))
        XCTAssertNil(WorkspaceIconPath.resolve("/System/Library/CoreServices/Finder.app/Contents/Resources/Finder.icns", in: root))
        XCTAssertNil(WorkspaceIconPath.resolve("notes.txt", in: root))
        XCTAssertNil(WorkspaceIconPath.resolve("public/missing.png", in: root))
        XCTAssertNil(WorkspaceIconPath.resolve("  \n", in: root))
    }

    func testAnotherProjectsIconInsideTheFolderIsNotTheFolders() throws {
        // ~/Developer holds projects; it isn't one.
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("octet-icon-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: dir) }
        let nested = dir.appendingPathComponent("locklandia/App/Assets.xcassets/AppIcon.appiconset")
        try FileManager.default.createDirectory(at: nested, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: dir.appendingPathComponent("locklandia/.git"), withIntermediateDirectories: true)
        try Data([0x89]).write(to: nested.appendingPathComponent("icon-1024.png"))
        let root = dir.path
        XCTAssertNil(WorkspaceIconPath.resolve("locklandia/App/Assets.xcassets/AppIcon.appiconset/icon-1024.png", in: root))
        // Opened as its own workspace, the same icon is the project's.
        let project = dir.appendingPathComponent("locklandia").path
        XCTAssertNotNil(WorkspaceIconPath.resolve("App/Assets.xcassets/AppIcon.appiconset/icon-1024.png", in: project))
        // The workspace's own .git doesn't count.
        try FileManager.default.createDirectory(at: dir.appendingPathComponent(".git"), withIntermediateDirectories: true)
        XCTAssertNil(WorkspaceIconPath.resolve("locklandia/App/Assets.xcassets/AppIcon.appiconset/icon-1024.png", in: root))
        XCTAssertFalse(WorkspaceIconPath.insideNestedProject(root + "/public/favicon.png", root: root, exists: { _ in false }))
        XCTAssertTrue(WorkspaceIconPath.insideNestedProject(root + "/a/b/icon.png", root: root, exists: { $0 == root + "/a/.git" }))
        XCTAssertFalse(WorkspaceIconPath.insideNestedProject(root + "/a/icon.png", root: root, exists: { $0 == root + "/.git" }))
    }

    func testWorkspaceIconsReadFromAManifest() throws {
        let manifest = try JSONDecoder().decode(OctetPluginManifest.self, from: Data(#"""
        {"id": "p", "name": "P", "contributes": {"workspaceIcons": [{"id": "favicon", "run": "sh find.sh", "refreshSeconds": 300}]}}
        """#.utf8))
        XCTAssertNil(OctetPlugins.validate(manifest))
        XCTAssertEqual(manifest.contributes.workspaceIcons.first?.run, "sh find.sh")
        let bad = try JSONDecoder().decode(OctetPluginManifest.self, from: Data(#"""
        {"id": "p", "name": "P", "contributes": {"workspaceIcons": [{"id": "Bad", "run": "x"}]}}
        """#.utf8))
        XCTAssertNotNil(OctetPlugins.validate(bad))
    }
}
