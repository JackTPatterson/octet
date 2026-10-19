import XCTest

final class ProjectConfigurationTests: XCTestCase {
    func testLocalOverridesAndNamedActions() throws {
        let shared = try ProjectConfiguration.decode(Data(#"{"version":1,"setup":"npm ci","waitForSetup":true,"actions":[{"id":"dev","name":"Dev","command":"npm run dev"},{"id":"test","name":"Test","command":"npm test"}]}"#.utf8))
        let local = try ProjectConfiguration.decode(Data(#"{"waitForSetup":false,"actions":[{"id":"dev","name":"Local Dev","command":"npm run dev -- --port 4100"}]}"#.utf8))
        let merged = shared.overriding(with: local)
        XCTAssertEqual(merged.setup, "npm ci")
        XCTAssertEqual(merged.waitForSetup, false)
        XCTAssertEqual(merged.actions?.map(\.id), ["test", "dev"])
        XCTAssertEqual(merged.actions?.last?.name, "Local Dev")
    }

    func testInvalidConfigurationDoesNotSilentlyFallBack() {
        for text in [#"{"version":2}"#, #"{"setpu":"echo unsafe"}"#, #"{"copyPaths":["../secret"]}"#,
                     #"{"copyPaths":[".git/config"]}"#, #"{"sharedDirectories":["/tmp"]}"#,
                     #"{"actions":[{"id":"x","name":"X","command":"a"},{"id":"x","name":"Y","command":"b"}]}"#] {
            XCTAssertThrowsError(try ProjectConfiguration.decode(Data(text.utf8)), text)
        }
        XCTAssertThrowsError(try ProjectConfiguration.decode(Data(repeating: 32, count: 256 * 1024 + 1)))
    }

    func testCopiesIgnoredPathsLinksDirectoriesAndPreservesExistingFiles() throws {
        let base = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: base) }
        let root = base.appendingPathComponent("repo"), checkout = base.appendingPathComponent("worktree")
        let fm = FileManager.default
        try fm.createDirectory(at: root.appendingPathComponent("cache"), withIntermediateDirectories: true)
        try fm.createDirectory(at: checkout, withIntermediateDirectories: true)
        try ".env\ncache/\nlocal.txt\nescape\n".write(to: root.appendingPathComponent(".gitignore"), atomically: true, encoding: .utf8)
        try "root-value".write(to: root.appendingPathComponent(".env"), atomically: true, encoding: .utf8)
        try "keep-mine".write(to: checkout.appendingPathComponent(".env"), atomically: true, encoding: .utf8)
        try "local".write(to: root.appendingPathComponent("local.txt"), atomically: true, encoding: .utf8)
        let git = Process(); git.executableURL = URL(fileURLWithPath: "/usr/bin/git")
        git.arguments = ["init", "-q", root.path]; try git.run(); git.waitUntilExit()
        XCTAssertEqual(git.terminationStatus, 0)
        let config = ProjectConfiguration(copyPaths: [".env", "local.txt"], sharedDirectories: ["cache"])
        XCTAssertEqual(try ProjectWorkspaceFiles.materialize(config, root: root.path, checkout: checkout.path), ["cache", "local.txt"])
        XCTAssertEqual(try String(contentsOf: checkout.appendingPathComponent(".env"), encoding: .utf8), "keep-mine")
        XCTAssertEqual(try fm.destinationOfSymbolicLink(atPath: checkout.appendingPathComponent("cache").path), root.appendingPathComponent("cache").path)
        XCTAssertEqual(try ProjectWorkspaceFiles.materialize(config, root: root.path, checkout: checkout.path), [])
        XCTAssertThrowsError(try ProjectWorkspaceFiles.materialize(.init(copyPaths: [".gitignore"]), root: root.path, checkout: checkout.path))
        try fm.createSymbolicLink(atPath: root.appendingPathComponent("escape").path, withDestinationPath: base.path)
        XCTAssertThrowsError(try ProjectWorkspaceFiles.materialize(.init(copyPaths: ["escape"]), root: root.path, checkout: checkout.path))
    }
}
