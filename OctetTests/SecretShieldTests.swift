import XCTest

@MainActor
final class SecretShieldTests: XCTestCase {
    func testFindsTokensByShapeAndEnvAssignments() {
        let stripe = "sk_live_" + String(repeating: "a1B2", count: 6)
        let github = "ghp_" + String(repeating: "x", count: 36)
        let found = SecretShield.find(in: "use \(stripe) and \(github)\nDATABASE_PASSWORD=hunter2hunter2\nPATH=/usr/bin")
        XCTAssertEqual(Set(found.map(\.name)), ["STRIPE_SECRET_KEY", "GITHUB_TOKEN", "DATABASE_PASSWORD"])
        XCTAssertEqual(found.first { $0.name == "DATABASE_PASSWORD" }?.value, "hunter2hunter2")
    }

    func testLeavesOrdinaryTextAndPlaceholdersAlone() {
        XCTAssertEqual(SecretShield.find(in: "API_KEY=$API_KEY\nTOKEN=short\nsk-short and a normal sentence"), [])
    }

    func testPrivateKeyIsOneSecret() {
        let key = "-----BEGIN PRIVATE KEY-----\nABCDEFGH\nIJKLMNOP\n-----END PRIVATE KEY-----"
        XCTAssertEqual(SecretShield.find(in: "here: \(key)").map(\.name), ["PRIVATE_KEY"])
    }

    func testShieldReplacesAndWritesAPrivateFile() throws {
        let vault = SecretVault(conversationID: "test-\(UUID().uuidString)")
        defer { vault.removeFile() }
        let token = "ghp_" + String(repeating: "y", count: 36)
        let result = vault.shield("push with \(token) please")
        XCTAssertEqual(result.text, "push with $GITHUB_TOKEN please")
        XCTAssertTrue(vault.note(for: result.added).contains(vault.fileURL.path))
        XCTAssertFalse(vault.note(for: result.added).contains(token))
        let file = try String(contentsOf: vault.fileURL, encoding: .utf8)
        XCTAssertTrue(file.contains("export GITHUB_TOKEN='\(token)'"))
        let mode = try FileManager.default.attributesOfItem(atPath: vault.fileURL.path)[.posixPermissions] as? Int
        XCTAssertEqual(mode, 0o600)
        // The same value later reuses its name and adds nothing.
        let again = vault.shield("again \(token)")
        XCTAssertEqual(again.text, "again $GITHUB_TOKEN")
        XCTAssertTrue(again.added.isEmpty)
    }

    func testMasksValueAndItsEncodings() {
        let vault = SecretVault(conversationID: "test-\(UUID().uuidString)")
        defer { vault.removeFile() }
        let token = "ghp_" + String(repeating: "z", count: 36)
        _ = vault.shield(token)
        let b64 = Data(token.utf8).base64EncodedString()
        XCTAssertEqual(vault.mask("out: \(token) / \(b64)"), "out: $GITHUB_TOKEN / $GITHUB_TOKEN")
        XCTAssertEqual(vault.environment["GITHUB_TOKEN"], token)
    }

    func testSameNameDifferentValueGetsASuffix() {
        let vault = SecretVault(conversationID: "test-\(UUID().uuidString)")
        defer { vault.removeFile() }
        _ = vault.shield("ghp_" + String(repeating: "a", count: 36))
        let second = vault.shield("ghp_" + String(repeating: "b", count: 36))
        XCTAssertEqual(second.added.map(\.name), ["GITHUB_TOKEN_2"])
    }
}
