import XCTest

final class QwenImagesTests: XCTestCase {
    func testTheFolderFollowsQwensRuntimeDirectory() {
        XCTAssertEqual(QwenImages.directory(environment: [:], home: "/Users/me"), "/Users/me/.qwen/tmp/octet")
        XCTAssertEqual(QwenImages.directory(environment: ["QWEN_HOME": "/q"], home: "/Users/me"), "/q/tmp/octet")
        XCTAssertEqual(QwenImages.directory(environment: ["QWEN_HOME": "/q", "QWEN_RUNTIME_DIR": "/r"], home: "/Users/me"),
                       "/r/tmp/octet")
    }

    func testMentionsComeBeforeTheText() {
        XCTAssertEqual(QwenImages.message("What's wrong here?", images: ["/Users/me/.qwen/tmp/octet/a.png"]),
                       "@/Users/me/.qwen/tmp/octet/a.png\nWhat's wrong here?")
        XCTAssertEqual(QwenImages.message("", images: ["/a b/x.jpg", "/y.png"]), "@/a\\ b/x.jpg @/y.png")
    }

    func testSavingWritesEachImageAndClearsOldOnes() throws {
        let directory = NSTemporaryDirectory() + "qwen-images-" + UUID().uuidString
        defer { try? FileManager.default.removeItem(atPath: directory) }
        let stale = try XCTUnwrap(QwenImages.save([(data: Data([1]), fileExtension: "png")], in: directory))
        try FileManager.default.setAttributes([.modificationDate: Date(timeIntervalSinceNow: -2 * 86_400)], ofItemAtPath: stale[0])
        let paths = try XCTUnwrap(QwenImages.save([(data: Data([2]), fileExtension: "jpg")], in: directory))
        XCTAssertEqual(try Data(contentsOf: URL(fileURLWithPath: paths[0])), Data([2]))
        XCTAssertTrue(paths[0].hasSuffix(".jpg"))
        XCTAssertFalse(FileManager.default.fileExists(atPath: stale[0]), "a day-old image is cleared")
    }
}
