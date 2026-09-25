import XCTest

final class KeyBytesTests: XCTestCase {
    func testCommonKeys() {
        XCTAssertEqual(KeyBytes.encode(keyCode: 0, characters: "a", modifiers: []), "a")
        XCTAssertEqual(KeyBytes.encode(keyCode: 36, characters: "\r", modifiers: []), "\r")
        XCTAssertEqual(KeyBytes.encode(keyCode: 51, characters: "\u{7f}", modifiers: []), "\u{7f}")
        XCTAssertEqual(KeyBytes.encode(keyCode: 126, characters: "\u{F700}", modifiers: []), "\u{1b}[A")
        XCTAssertEqual(KeyBytes.encode(keyCode: 8, characters: "c", modifiers: .control), "\u{03}")
        XCTAssertEqual(KeyBytes.encode(keyCode: 0, characters: "é", modifiers: .option), "é")
    }

    func testCommandKeysAndFunctionKeysArentMirrored() {
        XCTAssertNil(KeyBytes.encode(keyCode: 9, characters: "v", modifiers: .command))
        XCTAssertNil(KeyBytes.encode(keyCode: 122, characters: "\u{F704}", modifiers: []))
    }
}
