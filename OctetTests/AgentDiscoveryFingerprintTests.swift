import XCTest

final class AgentDiscoveryFingerprintTests: XCTestCase {
    private let home = "/Users/test"
    private let bin = "/opt/homebrew/bin"
    private let claude = "/opt/homebrew/bin/claude"

    /// A machine as stats would see it: a path with no entry isn't there.
    private func stamps(_ entries: [String: FileStamp]) -> (String) -> FileStamp {
        { entries[$0] ?? .missing }
    }

    private var machine: [String: FileStamp] {
        [bin: FileStamp(modified: 100, size: 64), claude: FileStamp(modified: 50, size: 1_000),
         home + "/.zshrc": FileStamp(modified: 10, size: 200)]
    }

    private func recorded(_ entries: [String: FileStamp]) -> AgentDiscoveryFingerprint {
        AgentDiscoveryFingerprint.record(shellPath: bin, directories: [bin, home + "/.bun/bin"],
                                         executables: [claude], home: home, stamp: stamps(entries))
    }

    func testNothingRecordedMeansScan() {
        XCTAssertTrue(AgentDiscoveryFingerprint.needsRescan(recorded: nil, stamp: stamps(machine)))
    }

    func testUnchangedMachineNeedsNoScan() {
        XCTAssertFalse(AgentDiscoveryFingerprint.needsRescan(recorded: recorded(machine), stamp: stamps(machine)))
    }

    func testNewFileInABinFolderMeansScan() {
        var now = machine
        now[bin] = FileStamp(modified: 200, size: 96)
        XCTAssertTrue(AgentDiscoveryFingerprint.needsRescan(recorded: recorded(machine), stamp: stamps(now)))
    }

    func testBinFolderAppearingMeansScan() {
        // `~/.bun/bin` wasn't there at the scan; a first `bun i -g` makes it.
        var now = machine
        now[home + "/.bun/bin"] = FileStamp(modified: 300, size: 64)
        XCTAssertTrue(AgentDiscoveryFingerprint.needsRescan(recorded: recorded(machine), stamp: stamps(now)))
    }

    func testRemovedBinaryMeansScan() {
        var now = machine
        now[claude] = nil
        XCTAssertTrue(AgentDiscoveryFingerprint.needsRescan(recorded: recorded(machine), stamp: stamps(now)))
    }

    func testUpdatedBinaryMeansScan() {
        var newer = machine
        newer[claude] = FileStamp(modified: 400, size: 1_000)
        XCTAssertTrue(AgentDiscoveryFingerprint.needsRescan(recorded: recorded(machine), stamp: stamps(newer)))
        // Same time, different size: still a different binary.
        var resized = machine
        resized[claude] = FileStamp(modified: 50, size: 2_000)
        XCTAssertTrue(AgentDiscoveryFingerprint.needsRescan(recorded: recorded(machine), stamp: stamps(resized)))
    }

    func testEditedShellProfileMeansScan() {
        var now = machine
        now[home + "/.zshrc"] = FileStamp(modified: 20, size: 240)
        XCTAssertTrue(AgentDiscoveryFingerprint.needsRescan(recorded: recorded(machine), stamp: stamps(now)))
    }

    func testFingerprintSurvivesSaving() throws {
        let fingerprint = recorded(machine)
        let data = try JSONEncoder().encode(fingerprint)
        XCTAssertEqual(try JSONDecoder().decode(AgentDiscoveryFingerprint.self, from: data), fingerprint)
    }

    /// The real stat, on a temporary folder: no shell, no agent CLI.
    func testRealStampsNoticeAnInstallAndAnUpdate() throws {
        let manager = FileManager.default
        let folder = manager.temporaryDirectory.appendingPathComponent(UUID().uuidString).path
        try manager.createDirectory(atPath: folder, withIntermediateDirectories: true)
        defer { try? manager.removeItem(atPath: folder) }
        let agent = folder + "/agent"
        manager.createFile(atPath: agent, contents: Data("#!/bin/sh\n".utf8), attributes: [.posixPermissions: 0o755])
        // Back-dated, so a change a moment later can't land on the same time.
        let past = Date(timeIntervalSinceNow: -3600)
        try manager.setAttributes([.modificationDate: past], ofItemAtPath: agent)
        try manager.setAttributes([.modificationDate: past], ofItemAtPath: folder)

        let fingerprint = AgentDiscoveryFingerprint.record(shellPath: folder, directories: [folder],
                                                           executables: [agent], home: folder)
        XCTAssertFalse(AgentDiscoveryFingerprint.needsRescan(recorded: fingerprint, stamp: FileStamp.of))

        manager.createFile(atPath: folder + "/other", contents: Data())
        XCTAssertTrue(AgentDiscoveryFingerprint.needsRescan(recorded: fingerprint, stamp: FileStamp.of))

        try manager.removeItem(atPath: folder + "/other")
        try manager.setAttributes([.modificationDate: past], ofItemAtPath: folder)
        XCTAssertFalse(AgentDiscoveryFingerprint.needsRescan(recorded: fingerprint, stamp: FileStamp.of))
        try Data("#!/bin/sh\necho 2\n".utf8).write(to: URL(fileURLWithPath: agent))
        XCTAssertTrue(AgentDiscoveryFingerprint.needsRescan(recorded: fingerprint, stamp: FileStamp.of))
    }
}
