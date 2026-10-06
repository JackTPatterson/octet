import XCTest

final class ConversationMoveTests: XCTestCase {
    func testEveryRecordsCwdIsPointedAtTheNewFolder() {
        let line = #"{"type":"user","cwd":"/Users/me/old","sessionId":"s1","message":{"role":"user","content":"hi"}}"#
        let moved = ConversationMove.rewriteCwd(in: line, to: "/Users/me/new")
        let object = try? JSONSerialization.jsonObject(with: Data(moved.utf8)) as? [String: Any]
        XCTAssertEqual(object?["cwd"] as? String, "/Users/me/new")
        XCTAssertEqual((object?["message"] as? [String: Any])?["content"] as? String, "hi")
        // Records without a cwd, and lines that aren't JSON, are left alone.
        XCTAssertEqual(ConversationMove.rewriteCwd(in: #"{"type":"summary","summary":"x"}"#, to: "/n"), #"{"type":"summary","summary":"x"}"#)
        XCTAssertEqual(ConversationMove.rewriteCwd(in: "", to: "/n"), "")
        XCTAssertEqual(ConversationMove.rewriteCwd(in: "not json \"cwd\"", to: "/n"), "not json \"cwd\"")
    }

    func testTheTranscriptAndItsSubagentsAreCopiedIntoTheNewProject() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("octet-move-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        let home = root.appendingPathComponent("home").path
        let old = "/Users/me/old", new = "/Users/me/new"
        let source = AgentConversation.claudeLogPath(sessionId: "s1", cwd: old, home: home)
        try FileManager.default.createDirectory(atPath: (source as NSString).deletingLastPathComponent, withIntermediateDirectories: true)
        try #"{"type":"user","cwd":"/Users/me/old","message":"a"}"#.write(toFile: source, atomically: true, encoding: .utf8)
        let sidecar = (source as NSString).deletingPathExtension
        try FileManager.default.createDirectory(atPath: sidecar, withIntermediateDirectories: true)
        try "sub".write(toFile: sidecar + "/agent-1.jsonl", atomically: true, encoding: .utf8)

        let destination = ConversationMove.claudeDestination(sessionId: "s1", folder: new, home: home)
        XCTAssertNotEqual(destination, source)
        XCTAssertTrue(destination.hasSuffix("/s1.jsonl"))
        try ConversationMove.copyClaudeTranscript(from: source, to: destination, folder: new)
        let copied = try String(contentsOfFile: destination, encoding: .utf8)
        XCTAssertTrue(copied.contains("\"cwd\":\"/Users/me/new\""), copied)
        XCTAssertTrue(FileManager.default.fileExists(atPath: (destination as NSString).deletingPathExtension + "/agent-1.jsonl"))
        // The original stays, so nothing is lost if the move goes wrong.
        XCTAssertTrue(FileManager.default.fileExists(atPath: source))
    }
}
