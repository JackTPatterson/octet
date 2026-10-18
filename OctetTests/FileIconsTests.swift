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
