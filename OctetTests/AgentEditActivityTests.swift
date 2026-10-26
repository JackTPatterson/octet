import XCTest
@testable import Octet

@MainActor
final class AgentEditActivityTests: XCTestCase {
    private func item(_ id: String, _ name: String, _ input: [String: Any], result: String? = nil, error: Bool = false) -> Octet.AgentItem {
        let call = Octet.AgentToolCall(name: name, summary: "", input: "", inputData: try? JSONSerialization.data(withJSONObject: input),
                                 result: result, isError: error)
        return Octet.AgentItem(id: id, kind: .tool(call))
    }

    func testEditsInFlightAndFinished() {
        let calls = AgentEditActivity.calls(in: [
            item("a", "Edit", ["file_path": "/tmp/a.swift", "old_string": "x", "new_string": "y"], result: "ok"),
            item("b", "Edit", ["file_path": "/tmp/b.swift", "old_string": "needle", "new_string": "y"]),
            item("c", "Write", ["file_path": "/tmp/c.swift", "content": "z"], result: "denied", error: true),
        ])
        XCTAssertEqual(calls.map(\.itemId), ["a", "b", "c"])
        XCTAssertEqual(calls.map(\.finished), [true, false, true])
        XCTAssertEqual(calls[1].oldString, "needle")
        XCTAssertTrue(calls[2].failed)
    }

    func testMultiEditUsesItsFirstEdit() {
        let calls = AgentEditActivity.calls(in: [
            item("m", "MultiEdit", ["file_path": "/tmp/m.swift",
                                    "edits": [["old_string": "first", "new_string": "1"], ["old_string": "second", "new_string": "2"]]]),
        ])
        XCTAssertEqual(calls.first?.oldString, "first")
    }

    func testOtherToolsAndTextAreIgnored() {
        let calls = AgentEditActivity.calls(in: [
            item("r", "Read", ["file_path": "/tmp/a.swift"], result: "..."),
            item("g", "Grep", ["pattern": "x"], result: "..."),
            Octet.AgentItem(id: "t", kind: .text("hello")),
        ])
        XCTAssertTrue(calls.isEmpty)
    }

    func testPathsAreCanonical() {
        let calls = AgentEditActivity.calls(in: [item("a", "Edit", ["file_path": "/tmp/../tmp/./a.swift"])])
        XCTAssertEqual(calls.first?.path, AgentEditActivity.canonical("/tmp/a.swift"))
    }
}
