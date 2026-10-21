import XCTest

final class BrowserAnnotationTests: XCTestCase {
    private var payload: [String: Any] {
        ["url": "https://user:pass@example.com/page?token=secret#private", "title": "Example", "selector": "#save",
         "html": "<button>Save</button>", "text": "Save", "styles": ["color": "red", "background-image": "url(secret)"],
         "rect": ["x": 5, "y": 10, "width": 100, "height": 30, "viewportWidth": 800, "viewportHeight": 600]]
    }
    func testCaptureSanitizesURLAndStyles() throws {
        let context = try BrowserElementContext.parse(payload)
        XCTAssertEqual(context.url, "https://example.com/page")
        XCTAssertEqual(context.styles, ["color": "red"])
    }
    func testInvalidGeometryAndSchemesAreRejected() {
        var value = payload; value["url"] = "file:///etc/passwd"
        XCTAssertThrowsError(try BrowserElementContext.parse(value))
        value = payload; value["rect"] = ["x": 0, "y": 0, "width": 0, "height": 30, "viewportWidth": 800, "viewportHeight": 600]
        XCTAssertThrowsError(try BrowserElementContext.parse(value))
    }
    func testPromptIncludesNotesAndContextInSelectionOrder() throws {
        let context = try BrowserElementContext.parse(payload)
        let prompt = BrowserAnnotation.prompt([.init(context: context, note: "Make this wider"), .init(context: context, note: "Use blue")])
        XCTAssertTrue(prompt.contains("Feedback 1: Make this wider"))
        XCTAssertTrue(prompt.contains("Feedback 2: Use blue"))
        XCTAssertTrue(prompt.contains("#save"))
        XCTAssertFalse(prompt.contains("token=secret"))
    }
}
