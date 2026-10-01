import CryptoKit
import XCTest

final class PluginRegistryTests: XCTestCase {
    private func entry(_ id: String, name: String, keywords: [String] = [], description: String = "",
                       files: [PluginRegistry.Entry.File]? = nil) -> PluginRegistry.Entry {
        PluginRegistry.Entry(id: id, name: name, description: description, keywords: keywords, repo: "o/r",
                             files: files ?? [.init(path: "plugin.json", sha256: String(repeating: "a", count: 64))])
    }

    func testParsesAnIndex() throws {
        let json = #"{"version":1,"plugins":[{"id":"issues","name":"Issues","repo":"o/r","ref":"v1","path":"plugins/issues","files":[{"path":"plugin.json","sha256":"\#(String(repeating: "0", count: 64))"}]}]}"#
        let registry = try PluginRegistry.parse(Data(json.utf8))
        XCTAssertEqual(registry.plugins.map(\.id), ["issues"])
        XCTAssertEqual(registry.plugins[0].url(of: registry.plugins[0].files[0])?.absoluteString,
                       "https://raw.githubusercontent.com/o/r/v1/plugins/issues/plugin.json")
        XCTAssertThrowsError(try PluginRegistry.parse(Data(#"{"version":99,"plugins":[]}"#.utf8)))
    }

    func testUnsafeEntriesAreRefused() {
        XCTAssertNil(entry("ok", name: "OK").problem)
        let hash = String(repeating: "b", count: 64)
        for path in ["../evil.sh", "/etc/passwd", "a/../../b", "~/x", "a//b", "./x"] {
            XCTAssertNotNil(entry("x", name: "X", files: [.init(path: "plugin.json", sha256: hash), .init(path: path, sha256: hash)]).problem, path)
        }
        XCTAssertNotNil(entry("x", name: "X", files: [.init(path: "plugin.json", sha256: "nothex")]).problem)
        XCTAssertNotNil(entry("x", name: "X", files: [.init(path: "run.sh", sha256: hash)]).problem, "no manifest")
        XCTAssertNotNil(entry("Bad Id", name: "X").problem)
    }

    func testSearchRanksNamesOverKeywordsOverDescriptions() {
        let entries = [entry("notes", name: "Notes", description: "Jot things; works with jira"),
                       entry("tracker", name: "Tracker", keywords: ["jira"]),
                       entry("jira", name: "Jira Issues")]
        XCTAssertEqual(PluginRegistry.search(entries, query: "jira").map(\.id), ["jira", "tracker", "notes"])
        XCTAssertEqual(PluginRegistry.search(entries, query: "jira track").map(\.id), ["tracker"])
        XCTAssertEqual(PluginRegistry.search(entries, query: "").map(\.id), ["jira", "notes", "tracker"])
    }

    func testVersions() {
        XCTAssertTrue(PluginRegistry.isNewer("1.2.0", than: "1.1.9"))
        XCTAssertTrue(PluginRegistry.isNewer("1.10", than: "1.9"))
        XCTAssertFalse(PluginRegistry.isNewer("1.0", than: "1.0.0"))
        XCTAssertFalse(PluginRegistry.isNewer("0.9.0", than: "1.0.0"))
    }

    /// Octet reads the plugins repository's index, every entry passes the
    /// installer's checks, and each checksum matches its file.
    func testThePluginsIndexIsOneOctetInstalls() throws {
        let repo = try TestPlugins.repository()
        let registry = try PluginRegistry.parse(Data(contentsOf: repo.appendingPathComponent("registry.json")))
        XCTAssertFalse(registry.plugins.isEmpty)
        for entry in registry.plugins {
            XCTAssertNil(entry.problem, entry.id)
            guard entry.repo == "JackTPatterson/octet-plugins" else { continue }
            let folder = repo.appendingPathComponent(entry.path)
            for file in entry.files {
                let bytes = try Data(contentsOf: folder.appendingPathComponent(file.path))
                let digest = SHA256.hash(data: bytes).map { String(format: "%02x", $0) }.joined()
                XCTAssertEqual(digest, file.sha256, "\(entry.id)/\(file.path) changed; rebuild the index")
            }
        }
    }
}
