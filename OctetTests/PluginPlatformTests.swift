import XCTest

final class PluginPlatformTests: XCTestCase {
    private func command(_ json: String) throws -> PluginCommand {
        try JSONDecoder().decode(PluginCommand.self, from: Data(json.utf8))
    }

    func testAStringIsShellForMacAndLinux() throws {
        let run = try command(#""sh chip.sh""#)
        XCTAssertEqual(run.command(for: .macos), "sh chip.sh")
        XCTAssertEqual(run.command(for: .linux), "sh chip.sh")
        XCTAssertNil(run.command(for: .windows))
        XCTAssertEqual(run.platforms, [.macos, .linux])
    }

    func testEachPlatformCanHaveItsOwn() throws {
        let run = try command(#"{"unix": "sh a.sh", "linux": "sh a-linux.sh", "windows": "& a.ps1"}"#)
        XCTAssertEqual(run.command(for: .macos), "sh a.sh")
        XCTAssertEqual(run.command(for: .linux), "sh a-linux.sh")
        XCTAssertEqual(run.command(for: .windows), "& a.ps1")
        let macOnly = try command(#"{"macos": "sh a.sh"}"#)
        XCTAssertEqual(macOnly.platforms, [.macos])
    }

    func testAPlainStringStaysAStringWhenWritten() throws {
        let data = try JSONEncoder().encode(PluginCommand("sh a.sh"))
        XCTAssertEqual(String(decoding: data, as: UTF8.self), #""sh a.sh""#)
    }

    func testEnvironmentPerShell() {
        XCTAssertEqual(PluginPlatform.macos.settingEnvironment("X", to: "a'b", before: "run"),
                       "X='a'\"'\"'b'; export X\nrun")
        XCTAssertEqual(PluginPlatform.windows.settingEnvironment("X", to: "a'b", before: "run"),
                       "$env:X = 'a''b'\nrun")
    }

    func testManifestsNamingUnknownPlatformsOrRunningNowhereAreRefused() throws {
        func manifest(_ run: String) throws -> OctetPluginManifest {
            try JSONDecoder().decode(OctetPluginManifest.self, from: Data(#"""
            {"id": "p", "name": "P", "contributes": {"statusItems": [{"id": "c", "name": "C", "run": \#(run)}]}}
            """#.utf8))
        }
        XCTAssertNil(OctetPlugins.validate(try manifest(#""sh c.sh""#)))
        XCTAssertNotNil(OctetPlugins.validate(try manifest(#"{"amiga": "run"}"#)))
        XCTAssertNotNil(OctetPlugins.validate(try manifest(#"{"windows": "  "}"#)))
        // A manifest with no platforms runs where sh does.
        XCTAssertEqual(try manifest(#""sh c.sh""#).supportedPlatforms, [.macos, .linux])
    }

    func testRegistryEntriesSayWhereTheyRun() throws {
        let hash = String(repeating: "0", count: 64)
        let json = #"{"version":1,"plugins":[{"id":"a","name":"A","repo":"o/r","platforms":["windows","beos"],"files":[{"path":"plugin.json","sha256":"\#(hash)"}]},{"id":"b","name":"B","repo":"o/r","files":[{"path":"plugin.json","sha256":"\#(hash)"}]}]}"#
        let registry = try PluginRegistry.parse(Data(json.utf8))
        XCTAssertEqual(registry.plugins[0].platforms, [.windows])
        XCTAssertEqual(registry.plugins[1].platforms, [.macos, .linux])
    }
}
