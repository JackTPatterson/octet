import XCTest
@testable import Octet

final class CredentialProfilesTests: XCTestCase {
    private let aventix = CredentialProfile(id: "a", name: "Aventix", variables: [
        CredentialVariable(name: "SUPABASE_ACCESS_TOKEN"),
        CredentialVariable(name: "AWS_REGION", secret: false, value: "us-east-1"),
    ])
    private let jpx = CredentialProfile(id: "j", name: "JPX", variables: [
        CredentialVariable(name: "SUPABASE_ACCESS_TOKEN"),
    ])

    private func secrets(_ account: String) -> String? {
        ["a:SUPABASE_ACCESS_TOKEN": "sbp_aventix", "j:SUPABASE_ACCESS_TOKEN": "sbp_jpx"][account]
    }

    func testEachFolderGetsItsOwnToken() {
        let assignments = [CredentialAssignment(folder: "/work/aventix", profileId: "a"),
                           CredentialAssignment(folder: "/work/jpx", profileId: "j")]
        let one = CredentialProfiles.environment(for: "/work/aventix/api", profiles: [aventix, jpx],
                                                 assignments: assignments, secret: secrets)
        XCTAssertEqual(one["SUPABASE_ACCESS_TOKEN"], "sbp_aventix")
        XCTAssertEqual(one["AWS_REGION"], "us-east-1")
        let two = CredentialProfiles.environment(for: "/work/jpx", profiles: [aventix, jpx],
                                                 assignments: assignments, secret: secrets)
        XCTAssertEqual(two["SUPABASE_ACCESS_TOKEN"], "sbp_jpx")
        XCTAssertNil(two["AWS_REGION"])
        XCTAssertTrue(CredentialProfiles.environment(for: "/elsewhere", profiles: [aventix, jpx],
                                                     assignments: assignments, secret: secrets).isEmpty)
    }

    func testDeeperFolderWinsAndSiblingsDontMatch() {
        let assignments = [CredentialAssignment(folder: "/work", profileId: "a"),
                           CredentialAssignment(folder: "/work/jpx", profileId: "j")]
        let env = CredentialProfiles.environment(for: "/work/jpx/app", profiles: [aventix, jpx],
                                                 assignments: assignments, secret: secrets)
        XCTAssertEqual(env["SUPABASE_ACCESS_TOKEN"], "sbp_jpx")
        // Not a prefix match on the name alone.
        XCTAssertTrue(CredentialProfiles.environment(for: "/work-other", profiles: [aventix],
                                                     assignments: assignments, secret: secrets).isEmpty)
    }

    func testMissingSecretsAreLeftUnset() {
        let assignments = [CredentialAssignment(folder: "/work", profileId: "a")]
        let env = CredentialProfiles.environment(for: "/work", profiles: [aventix], assignments: assignments,
                                                 secret: { _ in nil })
        XCTAssertNil(env["SUPABASE_ACCESS_TOKEN"])
        XCTAssertEqual(env["AWS_REGION"], "us-east-1")
    }

    func testWorktreeUsesItsProjectsProfile() {
        let assignments = [CredentialAssignment(folder: "/work/jpx", profileId: "j")]
        let env = CredentialProfiles.environment(for: "/elsewhere/wt", root: "/work/jpx", profiles: [jpx],
                                                 assignments: assignments, secret: secrets)
        XCTAssertEqual(env["SUPABASE_ACCESS_TOKEN"], "sbp_jpx")
    }
}
