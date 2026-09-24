import XCTest

final class SSHTargetTests: XCTestCase {
    func testHostAndUserFromTheDestination() {
        XCTAssertEqual(SSHTarget.parse(commandLine: "ssh prod-1"), SSHTarget(host: "prod-1", user: nil))
        XCTAssertEqual(SSHTarget.parse(commandLine: "ssh jack@192.168.86.58"), SSHTarget(host: "192.168.86.58", user: "jack"))
        XCTAssertEqual(SSHTarget.parse(commandLine: "/usr/bin/ssh root@pve"), SSHTarget(host: "pve", user: "root"))
        XCTAssertEqual(SSHTarget.parse(commandLine: "ssh ssh://deploy@example.com:2222"), SSHTarget(host: "example.com", user: "deploy"))
    }

    func testOptionsAndTheirValuesAreSkipped() {
        XCTAssertEqual(SSHTarget.parse(commandLine: "ssh -p 2222 -i ~/.ssh/key -o StrictHostKeyChecking=no box"),
                       SSHTarget(host: "box", user: nil))
        XCTAssertEqual(SSHTarget.parse(commandLine: "ssh -l admin -tt box"), SSHTarget(host: "box", user: "admin"))
        XCTAssertEqual(SSHTarget.parse(commandLine: "ssh -p2222 -J bastion box"), SSHTarget(host: "box", user: nil))
        XCTAssertEqual(SSHTarget.parse(commandLine: "ssh -4vA -- box"), SSHTarget(host: "box", user: nil))
    }

    func testRemoteCommandsAndOtherProgramsAreNotSessions() {
        XCTAssertNil(SSHTarget.parse(commandLine: "ssh git@github.com git-receive-pack 'octet.git'"))
        XCTAssertNil(SSHTarget.parse(commandLine: "ssh box uptime"))
        XCTAssertNil(SSHTarget.parse(commandLine: "sshd: jack@ttys001"))
        XCTAssertNil(SSHTarget.parse(commandLine: "ssh -p 22"))
        XCTAssertNil(SSHTarget.parse(commandLine: "ssh-agent -s"))
    }
}

final class RemoteShellTests: XCTestCase {
    func testMoshAndEternalTerminalAreRemoteSessionsToo() {
        XCTAssertEqual(SSHTarget.parse(commandLine: "mosh --ssh=ssh -p 60001 jack@pve"), SSHTarget(host: "pve", user: "jack"))
        XCTAssertEqual(SSHTarget.parse(commandLine: "et root@pve:2022"), SSHTarget(host: "pve", user: "root"))
    }
}
