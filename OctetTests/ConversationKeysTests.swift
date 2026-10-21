import AppKit
import SwiftUI
import XCTest
@testable import Octet

@MainActor
final class ConversationKeysTests: XCTestCase {
    func testCommandArrowCountsDespiteArrowKeyFlags() {
        XCTAssertTrue(ComposerKeys.isCommandOnly(.command))
        XCTAssertTrue(ComposerKeys.isCommandOnly([.command, .numericPad, .function]))
        XCTAssertFalse(ComposerKeys.isCommandOnly([.command, .shift, .numericPad]))
        XCTAssertFalse(ComposerKeys.isCommandOnly([.numericPad, .function]))
    }

    func testOnlyAPlainEscapeStops() {
        XCTAssertTrue(ConversationEscape.isPlainEscape(keyCode: 53, flags: []))
        XCTAssertTrue(ConversationEscape.isPlainEscape(keyCode: 53, flags: [.capsLock]))
        XCTAssertFalse(ConversationEscape.isPlainEscape(keyCode: 53, flags: [.command]))
        XCTAssertFalse(ConversationEscape.isPlainEscape(keyCode: 36, flags: []))
    }

    func testEditableTextAndOtherViewsKeepTheirEscape() {
        let editable = NSTextView()
        let selectable = NSTextView()
        selectable.isEditable = false
        XCTAssertTrue(ConversationEscape.takesEscape(editable))
        XCTAssertFalse(ConversationEscape.takesEscape(selectable))
        XCTAssertFalse(ConversationEscape.takesEscape(nil))
        XCTAssertFalse(ConversationEscape.takesEscape(NSHostingView(rootView: EmptyView())))
        // A terminal or any other AppKit view that took the keyboard.
        XCTAssertTrue(ConversationEscape.takesEscape(NSView()))
    }

    func testEscapeStopsOnlyTheConversationLastUsedInTheWindow() {
        let main = ConversationEscape.Candidate(id: "main", inMainArea: true)
        let beside = ConversationEscape.Candidate(id: "beside", inMainArea: false)
        // Nothing used yet: the one over the terminal.
        XCTAssertEqual(ConversationEscape.target(among: [beside, main], lastActive: nil), "main")
        XCTAssertEqual(ConversationEscape.target(among: [beside, main], lastActive: "beside"), "beside")
        XCTAssertEqual(ConversationEscape.target(among: [beside, main], lastActive: "main"), "main")
        // The last one used has gone from the window.
        XCTAssertEqual(ConversationEscape.target(among: [beside, main], lastActive: "closed"), "main")
        XCTAssertEqual(ConversationEscape.target(among: [beside], lastActive: "closed"), "beside")
        XCTAssertNil(ConversationEscape.target(among: [], lastActive: "main"))
    }

    func testEscapeFallsToTheConversationThatIsRunning() {
        let main = ConversationEscape.Candidate(id: "main", inMainArea: true, busy: false)
        let beside = ConversationEscape.Candidate(id: "beside", inMainArea: false, busy: true)
        // The one last used is idle: the running one stops instead.
        XCTAssertEqual(ConversationEscape.target(among: [beside, main], lastActive: "main"), "beside")
        // Both running: the one last used.
        let mainBusy = ConversationEscape.Candidate(id: "main", inMainArea: true, busy: true)
        XCTAssertEqual(ConversationEscape.target(among: [beside, mainBusy], lastActive: "main"), "main")
        XCTAssertEqual(ConversationEscape.target(among: [beside, mainBusy], lastActive: nil), "main")
    }
}
