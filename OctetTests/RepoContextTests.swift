import XCTest

final class RepoContextTests: XCTestCase {
    func testNearestMarkerWinsUpToTheRepoRoot() {
        let files: Set<String> = ["/repo/Cargo.toml", "/repo/web/package.json", "/repo/web/bun.lock"]
        let exists = { files.contains($0) }
        XCTAssertEqual(ProjectRuntime.detect(from: "/repo/web/src", root: "/repo", exists: exists)?.id, "bun")
        XCTAssertEqual(ProjectRuntime.detect(from: "/repo/crates/core", root: "/repo", exists: exists)?.id, "rust")
        XCTAssertNil(ProjectRuntime.detect(from: "/other", root: "/other", exists: exists))
    }

    func testMarkersAboveTheRootDoNotCount() {
        let exists = { $0 == "/home/package.json" }
        XCTAssertNil(ProjectRuntime.detect(from: "/home/repo/src", root: "/home/repo", exists: exists))
    }

    func testVersionIsReadFromEachToolsOutput() {
        XCTAssertEqual(ProjectRuntime.version(fromOutput: "v25.6.1\n"), "v25.6.1")
        XCTAssertEqual(ProjectRuntime.version(fromOutput: "Python 3.12.4"), "3.12.4")
        XCTAssertEqual(ProjectRuntime.version(fromOutput: "rustc 1.83.0 (90b35a623 2024-11-26)"), "1.83.0")
        XCTAssertEqual(ProjectRuntime.version(fromOutput: "go version go1.23.2 darwin/arm64"), "1.23.2")
        XCTAssertEqual(ProjectRuntime.version(
            fromOutput: "swift-driver version: 1.115.1 Apple Swift version 6.1 (swiftlang-6.1.0.110.21)"), "6.1")
        XCTAssertNil(ProjectRuntime.version(fromOutput: "command not found: node"))
    }
}
