import XCTest

final class PromptLinkTests: XCTestCase {
    func testBuildsAndReadsANewConversationLink() {
        let link = OctetURL.new(prompt: "Fix the flaky test & ship it? 100% + more", dir: "/src/my api", agent: "codex")
        XCTAssertTrue(link.url.absoluteString.hasPrefix("octet://new?prompt="))
        // "+" is escaped so a link pasted somewhere that reads it as a space survives.
        XCTAssertFalse(link.url.absoluteString.contains("+"))
        XCTAssertEqual(OctetURL(link.url), link)
        XCTAssertEqual(OctetURL(URL(string: "octet://new?prompt=Hello%20there")!), .new(prompt: "Hello there", dir: nil, agent: nil))
        XCTAssertEqual(OctetURL(URL(string: "octet://new?prompt=Hi&dir=~/api&agent=Claude")!),
                       .new(prompt: "Hi", dir: NSHomeDirectory() + "/api", agent: "claude"))
    }

    func testRoundTripsAcrossPrompts() {
        for prompt in ["one line", "two\nlines", "emoji 👩‍💻 joined", "quotes \"and\" 'these' = &&", "https://x.y/?a=b&c=d#e"] {
            let command = OctetURL.new(prompt: prompt, dir: "/x", agent: "claude")
            XCTAssertEqual(OctetURL(command.url), command, prompt)
            XCTAssertEqual(OctetURL(URL(string: command.url.absoluteString)!), command, prompt)
        }
    }

    func testRejectsLinksItShouldntOpen() {
        XCTAssertNil(OctetURL(URL(string: "octet://new")!))
        XCTAssertNil(OctetURL(URL(string: "octet://new?prompt=")!))
        XCTAssertNil(OctetURL(URL(string: "octet://new?prompt=%E2%80%8B%E2%80%8B")!))  // only zero-width spaces
        XCTAssertNil(OctetURL(URL(string: "octet://new?prompt=hi&agent=rm%20-rf")!))
        let long = String(repeating: "a", count: PromptLink.maximumPromptLength + 1)
        XCTAssertNil(OctetURL(OctetURL.new(prompt: long, dir: nil, agent: nil).url))
    }

    func testStripsHiddenCharacters() {
        let sanitized = PromptLink.sanitize("Do\u{200B} this\u{202E}\u{E0041}\r\nthen\u{2028}that ")
        XCTAssertEqual(sanitized.text, "Do this\nthen\nthat")
        XCTAssertEqual(sanitized.hiddenCharacters, 3)
        // A joiner inside an emoji is kept; a stray one isn't.
        XCTAssertEqual(PromptLink.sanitize("👩\u{200D}💻").text, "👩\u{200D}💻")
        XCTAssertEqual(PromptLink.sanitize("a\u{200D}b").text, "ab")
        XCTAssertEqual(OctetURL(URL(string: "octet://new?prompt=a%E2%80%8Bb")!), .new(prompt: "ab", dir: nil, agent: nil))
    }

    func testLastPromptAndItsLink() {
        let items = [
            AgentItem(id: "1", kind: .user("First ask")),
            AgentItem(id: "2", kind: .text("An answer")),
            AgentItem(id: "3", kind: .user("Second ask")),
            AgentItem(id: "4", kind: .user("sub task"), parent: "t1"),
            AgentItem(id: "5", kind: .user("! ls")),
            AgentItem(id: "6", kind: .user("queued one"), queued: true),
        ]
        XCTAssertEqual(PromptLink.lastPrompt(in: items), "Second ask")
        XCTAssertNil(PromptLink.lastPrompt(in: [AgentItem(id: "1", kind: .text("x"))]))
        let url = PromptLink.link(prompt: "Second ask", dir: "/p", agent: "claude")
        XCTAssertEqual(url.flatMap(OctetURL.init), .new(prompt: "Second ask", dir: "/p", agent: "claude"))
        // Too long for a link: cut to fit rather than refused.
        let long = PromptLink.link(prompt: String(repeating: "b", count: 9000), dir: nil, agent: nil)
        if case .new(let prompt, _, _)? = long.flatMap(OctetURL.init) {
            XCTAssertEqual(prompt.count, PromptLink.maximumPromptLength)
        } else {
            XCTFail("expected a link")
        }
    }

    func testAChipCantOpenAPromptLink() {
        XCTAssertNil(StatusItemOutput.parse("x\nurl: octet://new?prompt=hi")?.url)
    }
}
