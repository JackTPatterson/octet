import XCTest

final class ProjectFileIndexTests: XCTestCase {
    func testGitListParsing() {
        XCTAssertEqual(ProjectFileIndex.parseGitList("a.swift\0b/c.md\0a.swift\0"), ["a.swift", "b/c.md"])
        XCTAssertEqual(ProjectFileIndex.parseGitList(""), [])
    }

    func testCapSaysItCapped() {
        let result = ProjectFileIndex.finish(["c", "a", "b"], limit: 2, fromGit: false)
        XCTAssertEqual(result.paths, ["a", "b"])
        XCTAssertTrue(result.truncated)
        XCTAssertFalse(ProjectFileIndex.finish(["a"], limit: 2, fromGit: false).truncated)
    }

    func testGitCheckoutHonoursGitignore() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("octet-index-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        let manager = FileManager.default
        try manager.createDirectory(at: root.appendingPathComponent("src"), withIntermediateDirectories: true)
        try manager.createDirectory(at: root.appendingPathComponent("dist"), withIntermediateDirectories: true)
        try "dist/\n*.log\n".write(to: root.appendingPathComponent(".gitignore"), atomically: true, encoding: .utf8)
        try "x".write(to: root.appendingPathComponent("src/main.swift"), atomically: true, encoding: .utf8)
        try "x".write(to: root.appendingPathComponent("dist/bundle.js"), atomically: true, encoding: .utf8)
        try "x".write(to: root.appendingPathComponent("debug.log"), atomically: true, encoding: .utf8)
        try Git().run(["init", "-q"], in: root.path)

        let result = ProjectFileIndex.list(root: root.path)
        XCTAssertTrue(result.fromGit)
        XCTAssertEqual(result.paths, [".gitignore", "src/main.swift"])
    }

    func testStatusMarksFilesAndTheirFolders() {
        let changes = [
            AgentGit.FileChange(path: "app/web/src/a.ts", kind: .modified, staged: false),
            AgentGit.FileChange(path: "app/web/new.ts", kind: .untracked, staged: false),
            AgentGit.FileChange(path: "other/b.ts", kind: .added, staged: true),
        ]
        let status = ProjectGitStatus(changes: changes, prefix: "app/web")
        XCTAssertEqual(status.files, ["src/a.ts": .modified, "new.ts": .untracked])
        XCTAssertEqual(status.folders, ["src"])
    }
}
