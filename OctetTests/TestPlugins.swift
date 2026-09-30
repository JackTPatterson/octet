import XCTest

/// The octet-plugins repository, for tests of the real plugins: CI checks
/// it out inside this one; locally it's a clone beside Octet, or wherever
/// OCTET_PLUGINS_DIR says.
enum TestPlugins {
    static func repository() throws -> URL {
        let octet = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
        let candidates = [
            ProcessInfo.processInfo.environment["OCTET_PLUGINS_DIR"].map { URL(fileURLWithPath: $0) },
            octet.appendingPathComponent("octet-plugins"),
            octet.deletingLastPathComponent().appendingPathComponent("octet-plugins"),
        ].compactMap { $0 }
        guard let found = candidates.first(where: {
            FileManager.default.fileExists(atPath: $0.appendingPathComponent("registry.json").path)
        }) else {
            throw XCTSkip("Clone JackTPatterson/octet-plugins beside Octet to test its plugins")
        }
        return found
    }

    /// Its plugins folder, to discover plugins from.
    static func pluginsPath() throws -> String {
        try repository().appendingPathComponent("plugins").path
    }
}
