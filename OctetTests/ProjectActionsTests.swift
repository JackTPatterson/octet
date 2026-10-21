import XCTest
@testable import Octet

@MainActor
final class ProjectActionsTests: XCTestCase {
    func testRepositoryActionsRemainScopedToTheirCheckoutAndLocalOverridesWin() throws {
        let base = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: base) }
        let main = base.appendingPathComponent("main"), branch = base.appendingPathComponent("branch")
        try FileManager.default.createDirectory(at: main, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: branch, withIntermediateDirectories: true)
        try Data(#"{"actions":[{"id":"dev","name":"Main Dev","command":"npm run dev"}]}"#.utf8).write(to: main.appendingPathComponent("octet.json"))
        try Data(#"{"actions":[{"id":"dev","name":"Branch Dev","command":"bun dev"}]}"#.utf8).write(to: branch.appendingPathComponent("octet.json"))
        let store = ProjectActionsStore(defaults: defaults())
        store.refreshConfiguration(root: main.path, checkout: main.path)
        store.refreshConfiguration(root: main.path, checkout: branch.path)
        XCTAssertEqual(store.actions(for: main.path, checkout: main.path).first?.name, "Main Dev")
        XCTAssertEqual(store.actions(for: main.path, checkout: branch.path).first?.command, "bun dev")
        store.save(ProjectAction(id: "dev", name: "My Dev", command: "local-dev"), root: main.path, isNew: false)
        XCTAssertEqual(store.actions(for: main.path, checkout: branch.path).first?.command, "local-dev")
        store.delete("dev", root: main.path)
        XCTAssertEqual(store.actions(for: main.path, checkout: branch.path).first?.command, "bun dev")
    }

    private func defaults() -> UserDefaults {
        let suite = "octet.projectActions.tests.\(UUID().uuidString)"
        let d = UserDefaults(suiteName: suite)!
        d.removePersistentDomain(forName: suite)
        return d
    }

    func testPackageScriptsUseTheLockfilesManagerAndSkipHooks() {
        let json = #"{"scripts":{"zeta":"x","build":"b","dev":"d","prebuild":"p","test":"t"}}"#
        let actions = ProjectActionSuggestions.packageScripts(Data(json.utf8), manager: "pnpm")
        XCTAssertEqual(actions.map(\.command), ["pnpm run dev", "pnpm run build", "pnpm run test", "pnpm run zeta"])
        XCTAssertEqual(ProjectActionSuggestions.packageManager(has: { $0 == "yarn.lock" }), "yarn")
        XCTAssertEqual(ProjectActionSuggestions.packageManager(has: { _ in false }), "npm")
    }

    func testMakeTargetsSkipAssignmentsPatternsAndSpecials() {
        let text = "CC := gcc\nVAR = 1\n.PHONY: all\nall: build\n\tcc\nbuild test:\n\techo\n%.o: %.c\n\tcc\n"
        XCTAssertEqual(ProjectActionSuggestions.makeTargets(text).map(\.command), ["make build", "make test", "make all"])
    }

    func testSuggestionsReadTheProjectFolder() throws {
        let dir = NSTemporaryDirectory() + "pa-\(UUID().uuidString)"
        try FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(atPath: dir) }
        try #"{"scripts":{"dev":"vite"}}"#.write(toFile: dir + "/package.json", atomically: true, encoding: .utf8)
        try "".write(toFile: dir + "/bun.lock", atomically: true, encoding: .utf8)
        try "[package]".write(toFile: dir + "/Cargo.toml", atomically: true, encoding: .utf8)
        let found = ProjectActionSuggestions.suggestions(in: dir).map(\.command)
        XCTAssertEqual(found.first, "bun run dev")
        XCTAssertTrue(found.contains("cargo test"))
    }

    func testStorePersistsPerRootAndKeepsIdsUnique() {
        let d = defaults()
        let store = ProjectActionsStore(defaults: d)
        let a = store.save(ProjectAction(id: "", name: "Test it", command: "make test"), root: "/p", isNew: true)
        let b = store.save(ProjectAction(id: "", name: "Test it", command: "make t2"), root: "/p", isNew: true)
        XCTAssertEqual([a.id, b.id], ["test-it", "test-it-2"])
        var edited = a
        edited.command = "make check"
        store.save(edited, root: "/p", isNew: false)
        XCTAssertEqual(ProjectActionsStore(defaults: d).actions(for: "/p").map(\.command), ["make check", "make t2"])
        XCTAssertEqual(ProjectActionsStore(defaults: d).actions(for: "/q"), [])
        store.delete("test-it", root: "/p")
        XCTAssertEqual(ProjectActionsStore(defaults: d).actions(for: "/p").map(\.id), ["test-it-2"])
    }

    func testRunLineQuotesTheFolder() {
        let action = ProjectAction(id: "t", name: "t", command: "make test")
        XCTAssertEqual(ProjectActionRunner.line(for: action, in: "/a b/it's"), "cd '/a b/it'\\''s' && make test")
    }
}
