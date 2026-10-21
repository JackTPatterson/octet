import XCTest

final class TextEncodingTests: XCTestCase {
    func testUTF8WithAndWithoutMark() throws {
        let plain = try XCTUnwrap(TextEncoding.decode(Data("héllo\n".utf8)))
        XCTAssertEqual(plain.text, "héllo\n")
        XCTAssertEqual(plain.encodingName, "UTF-8")
        let marked = try XCTUnwrap(TextEncoding.decode(Data([0xEF, 0xBB, 0xBF]) + Data("hi".utf8)))
        XCTAssertEqual(marked.text, "hi")
        XCTAssertEqual(marked.encodingName, "UTF-8 with BOM")
        XCTAssertEqual(TextEncoding.encode(marked.text, as: marked.encoding, byteOrderMark: true),
                       Data([0xEF, 0xBB, 0xBF]) + Data("hi".utf8))
    }

    func testUTF16RoundTripsWithItsMark() throws {
        let data = Data([0xFF, 0xFE]) + "a\r\nb".data(using: .utf16LittleEndian)!
        let decoded = try XCTUnwrap(TextEncoding.decode(data))
        XCTAssertEqual(decoded.text, "a\r\nb")
        XCTAssertEqual(decoded.encodingName, "UTF-16 LE")
        XCTAssertEqual(decoded.lineEnding, .crlf)
        XCTAssertEqual(TextEncoding.encode(decoded.text, as: decoded.encoding, byteOrderMark: true), data)
    }

    func testLatinTextIsNotBinary() throws {
        // "café" in Windows-1252: é is 0xE9, invalid on its own in UTF-8.
        let decoded = try XCTUnwrap(TextEncoding.decode(Data([0x63, 0x61, 0x66, 0xE9])))
        XCTAssertEqual(decoded.text, "café")
        XCTAssertEqual(decoded.encodingName, "Windows-1252")
    }

    func testBinaryIsRefused() {
        XCTAssertNil(TextEncoding.decode(Data([0x89, 0x50, 0x4E, 0x47, 0x00, 0x01])))
    }

    func testLineEndings() {
        XCTAssertEqual(TextEncoding.lineEnding(of: "a\nb"), .lf)
        XCTAssertEqual(TextEncoding.lineEnding(of: "a\r\nb\n"), .crlf)
        XCTAssertEqual(TextEncoding.lineEnding(of: "a\rb"), .cr)
        XCTAssertEqual(TextEncoding.lineEnding(of: "one line"), .lf)
    }
}
