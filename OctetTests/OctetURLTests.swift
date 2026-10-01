import XCTest

final class OctetURLTests: XCTestCase {
    func testReadsEachCommand() {
        XCTAssertEqual(OctetURL(URL(string: "octet://open?path=/src/api")!), .open(path: "/src/api"))
        XCTAssertEqual(OctetURL(URL(string: "octet://run?agent=claude&path=/src/api&prompt=Fix%20the%20tests")!),
                       .run(agent: "claude", path: "/src/api", prompt: "Fix the tests"))
        XCTAssertEqual(OctetURL(URL(string: "octet://run?agent=codex")!), .run(agent: "codex", path: nil, prompt: nil))
        XCTAssertEqual(OctetURL(URL(string: "octet://send?text=npm%20test")!), .send(text: "npm test"))
        XCTAssertEqual(OctetURL(URL(string: "OCTET://OPEN?path=~/x")!), .open(path: NSHomeDirectory() + "/x"))
    }

    func testRejectsWhatItCantDoSafely() {
        XCTAssertNil(OctetURL(URL(string: "octet://open")!))
        XCTAssertNil(OctetURL(URL(string: "octet://run?agent=rm%20-rf")!))   // not an agent name
        XCTAssertNil(OctetURL(URL(string: "octet://format-disk")!))
        XCTAssertNil(OctetURL(URL(string: "https://open?path=/x")!))
    }

    func testRoundTrips() {
        for command in [OctetURL.open(path: "/a b/c"), .run(agent: "claude", path: "/x", prompt: "fix & ship?"), .send(text: "ls -la")] {
            XCTAssertEqual(OctetURL(command.url), command)
        }
    }

    func testPluginInstallLinks() {
        XCTAssertEqual(OctetURL(URL(string: "octet://plugin?id=containers")!), .installPlugin(id: "containers"))
        XCTAssertEqual(OctetURL.installPlugin(id: "issues").url.absoluteString, "octet://plugin?id=issues")
        // Only registry ids: nothing that could name a path.
        XCTAssertNil(OctetURL(URL(string: "octet://plugin?id=../evil")!))
        XCTAssertNil(OctetURL(URL(string: "octet://plugin")!))
    }

    func testPluginSettingsLinksAndWhichAChipMayOpen() {
        XCTAssertEqual(OctetURL(URL(string: "octet://plugin-settings?id=issues")!), .pluginSettings(id: "issues"))
        XCTAssertEqual(OctetURL.pluginSettings(id: "issues").url.absoluteString, "octet://plugin-settings?id=issues")
        // A chip may open a plugin's settings, never a link that types or installs.
        XCTAssertEqual(StatusItemOutput.parse("NXS-528\nurl: octet://plugin-settings?id=issues")?.url?.absoluteString,
                       "octet://plugin-settings?id=issues")
        XCTAssertNil(StatusItemOutput.parse("x\nurl: octet://send?text=rm")?.url)
        XCTAssertNil(StatusItemOutput.parse("x\nurl: octet://plugin?id=evil")?.url)
        XCTAssertNil(StatusItemOutput.parse("x\nurl: file:///etc/passwd")?.url)
    }
}
