import XCTest

final class FileIconsTests: XCTestCase {
    func testKindsByExtension() {
        XCTAssertEqual(FileIcons.symbol(forName: "logo.PNG"), "photo")
        XCTAssertEqual(FileIcons.symbol(forName: "demo.mp4"), "film")
        XCTAssertEqual(FileIcons.symbol(forName: "spec.pdf"), "doc.richtext")
        XCTAssertEqual(FileIcons.symbol(forName: "build.tar"), "doc.zipper")
        XCTAssertEqual(FileIcons.symbol(forName: "notes.txt"), "doc.text")
        XCTAssertEqual(FileIcons.symbol(forName: "run.sh"), "terminal")
    }

    func testByName() {
        XCTAssertEqual(FileIcons.symbol(forName: ".gitignore"), "gearshape")
        XCTAssertEqual(FileIcons.symbol(forName: ".env.local"), "key")
        XCTAssertEqual(FileIcons.symbol(forName: "Makefile"), "terminal")
        XCTAssertEqual(FileIcons.symbol(forName: "yarn.lock"), "lock")
        XCTAssertEqual(FileIcons.symbol(forName: "package-lock.json"), "lock")
    }

    func testUnknownIsADocument() {
        XCTAssertEqual(FileIcons.symbol(forName: "thing.zzz"), "doc")
        XCTAssertEqual(FileIcons.symbol(forName: "noextension"), "doc")
    }
}

final class AgentLocationNameTests: XCTestCase {
    func testAgentWorktreesReadShort() {
        XCTAssertEqual(AgentLocation.shortName(".claude/worktrees/agent-ab11ed502677cd26a"), "agent ab11")
        XCTAssertEqual(AgentLocation.shortName("_worktrees/herd/plane-loading-skeletons"), "herd/plane-loading-skeletons")
    }

    func testPlainNamesStay() {
        XCTAssertEqual(AgentLocation.shortName("web"), "web")
        XCTAssertEqual(AgentLocation.shortName("server/"), "server")
    }

    func testDeepFoldersKeepTheirLastTwo() {
        XCTAssertEqual(AgentLocation.shortName("a/b/c/d"), "…/c/d")
    }
}
