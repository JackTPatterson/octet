import XCTest

final class PluginSettingsTests: XCTestCase {
    private func manifest(_ settings: String) throws -> OctetPluginManifest {
        try JSONDecoder().decode(OctetPluginManifest.self, from: Data(#"{"id": "p", "name": "P", "settings": \#(settings)}"#.utf8))
    }

    func testSettingsReadFromAManifest() throws {
        let plugin = try manifest(#"""
        [{"id": "JIRA_URL", "title": "Jira site", "placeholder": "https://acme.atlassian.net"},
         {"id": "JIRA_API_TOKEN", "title": "API token", "secret": true, "link": "https://id.atlassian.com/manage-profile/security/api-tokens"}]
        """#)
        XCTAssertNil(OctetPlugins.validate(plugin))
        XCTAssertEqual(plugin.settings?.map(\.id), ["JIRA_URL", "JIRA_API_TOKEN"])
        XCTAssertEqual(plugin.settings?.map(\.isSecret), [false, true])
        XCTAssertEqual(plugin.settings?.last?.linkURL?.host, "id.atlassian.com")
        // No settings is fine, and old manifests have none.
        XCTAssertNil(try JSONDecoder().decode(OctetPluginManifest.self, from: Data(#"{"id": "p", "name": "P"}"#.utf8)).settings)
    }

    func testBadSettingsAreRefused() throws {
        for settings in [#"[{"id": "jira_url", "title": "A"}]"#,       // not an environment variable name
                         #"[{"id": "PATH", "title": "A"}]"#,           // changes how commands run
                         #"[{"id": "DYLD_INSERT_LIBRARIES", "title": "A"}]"#,
                         #"[{"id": "OCTET_CWD", "title": "A"}]"#,      // Octet's own
                         #"[{"id": "A", "title": " "}]"#,
                         #"[{"id": "A", "title": "A"}, {"id": "A", "title": "B"}]"#] {
            XCTAssertNotNil(OctetPlugins.validate(try manifest(settings)), settings)
        }
        // Only web links to get a value from.
        XCTAssertNil(try manifest(#"[{"id": "A", "title": "A", "link": "file:///etc"}]"#).settings?.first?.linkURL)
    }

    func testGeneratorsCarryTheirEnvironment() {
        let generator = CompletionSpec.Generator(id: "g", command: "printf %s \"$JIRA_URL\"", environment: ["JIRA_URL": "https://acme.atlassian.net"])
        XCTAssertEqual(generator.environment["JIRA_URL"], "https://acme.atlassian.net")
        XCTAssertFalse(generator.command.contains("acme"), "values never go on the command line")
    }
}
