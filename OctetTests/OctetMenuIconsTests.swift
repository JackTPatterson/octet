import XCTest
@testable import Octet

final class OctetMenuIconsTests: XCTestCase {
    func testVerbsGetTheirIcons() {
        XCTAssertEqual(OctetMenuIcons.guess("Copy Path"), "doc.on.doc")
        XCTAssertEqual(OctetMenuIcons.guess("Rename…"), "pencil")
        XCTAssertEqual(OctetMenuIcons.guess("Delete Branch"), "trash")
        XCTAssertEqual(OctetMenuIcons.guess("Close Others"), "xmark")
        XCTAssertEqual(OctetMenuIcons.guess("Reveal in Finder"), "folder")
        XCTAssertEqual(OctetMenuIcons.guess("Open in Browser"), "arrow.up.right")
        XCTAssertEqual(OctetMenuIcons.guess("Unpin"), "pin.slash")
        XCTAssertEqual(OctetMenuIcons.guess("Pin to Top"), "pin")
        XCTAssertEqual(OctetMenuIcons.guess("Split Right"), "rectangle.split.2x1")
        XCTAssertEqual(OctetMenuIcons.guess("Mark as Read"), "checkmark.circle")
        XCTAssertEqual(OctetMenuIcons.guess("New Tab"), "plus")
    }

    func testTheMoreSpecificRuleWins() {
        XCTAssertEqual(OctetMenuIcons.guess("Open Pull Request"), "pull.request")
        XCTAssertEqual(OctetMenuIcons.guess("Copy Link"), "doc.on.doc")
        XCTAssertEqual(OctetMenuIcons.guess("Run in Terminal"), "terminal")
    }

    func testNamesAndSentencesAreLeftAlone() {
        XCTAssertNil(OctetMenuIcons.guess("main"))
        XCTAssertNil(OctetMenuIcons.guess("feature/delete-everything"))
        XCTAssertNil(OctetMenuIcons.guess("Closer to the edge"))
        XCTAssertNil(OctetMenuIcons.guess("Remove the trailing whitespace from every file in the project folder"))
        XCTAssertNil(OctetMenuIcons.guess(""))
    }

    func testEveryIconExists() {
        let titles = ["Copy", "Rename", "Delete", "Close", "Hide", "Show", "New", "Duplicate", "Refresh", "Undo", "Stop", "Run",
                      "Save", "Search", "Settings", "Snooze", "Archive", "Approve", "Reject", "Merge", "Checkout", "Commit", "Tag",
                      "Compare", "Reply", "Move", "Info", "Color", "Link", "Expand", "Unpin", "Pin", "Mark as Unread"]
        for title in titles {
            let icon = try? XCTUnwrap(OctetMenuIcons.guess(title), title)
            XCTAssertNotNil(icon.flatMap { OctetIcon.map[$0] }, "\(title) → \(icon ?? "nil")")
        }
    }
}
