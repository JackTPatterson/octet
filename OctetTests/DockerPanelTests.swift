import XCTest
import AppKit
@testable import Octet

final class DockerPanelTests: XCTestCase {
    @MainActor func testLogColoringPreservesTextAndHonorsANSI() {
        let plain = "2026-10-18T12:00:00Z INFO ready\nERROR failed\n{\"ok\":true}"
        let rendered = ContainerLogColors.render(plain)
        XCTAssertEqual(rendered.string, plain)
        let info = (plain as NSString).range(of: "INFO").location
        let error = (plain as NSString).range(of: "ERROR").location
        XCTAssertNotEqual(rendered.attribute(.foregroundColor, at: info, effectiveRange: nil) as? NSColor,
                          rendered.attribute(.foregroundColor, at: error, effectiveRange: nil) as? NSColor)
        let ansi = ContainerLogColors.render("\u{001B}[31mred\u{001B}[0m normal")
        XCTAssertEqual(ansi.string, "red normal")
        XCTAssertNotEqual(ansi.attribute(.foregroundColor, at: 0, effectiveRange: nil) as? NSColor,
                          ansi.attribute(.foregroundColor, at: 4, effectiveRange: nil) as? NSColor)
        XCTAssertEqual(ContainerLogColors.render("\u{001B}[38;2;255;0;0m你好\u{001B}[0m").string, "你好")
    }

    private func container(_ state: String) throws -> DockerContainer {
        try JSONDecoder().decode(DockerContainer.self, from: Data("""
        {"ID":"abc123","Names":"api","Image":"app:latest","State":"\(state)","Status":"\(state)","Ports":"8080->80/tcp","Labels":"com.docker.compose.project=demo,com.docker.compose.service=api,com.docker.compose.project.working_dir=/projects/demo/server","Platform":{"os":"linux","architecture":"arm64"}}
        """.utf8))
    }

    func testStateSpecificActionsAndSafeRemoval() throws {
        let running = try container("running"), paused = try container("paused"), exited = try container("exited")
        XCTAssertTrue(DockerAction.stop.allowed(for: running))
        XCTAssertTrue(DockerAction.pause.allowed(for: running))
        XCTAssertFalse(DockerAction.start.allowed(for: running))
        XCTAssertFalse(DockerAction.remove.allowed(for: running))
        XCTAssertTrue(DockerAction.unpause.allowed(for: paused))
        XCTAssertFalse(DockerAction.remove.allowed(for: paused))
        XCTAssertTrue(DockerAction.start.allowed(for: exited))
        XCTAssertTrue(DockerAction.remove.allowed(for: exited))
        XCTAssertEqual(DockerAction.remove.command(id: "abc123"), ["container", "rm", "abc123"])
        XCTAssertEqual(DockerAction.stop.command(id: "abc123"), ["container", "stop", "--time", "10", "abc123"])
    }

    func testComposeScopeAndSearch() throws {
        let row = try container("running")
        XCTAssertEqual(row.project, "demo")
        XCTAssertEqual(row.service, "api")
        XCTAssertTrue(row.belongs(to: "/projects/demo"))
        XCTAssertTrue(row.belongs(to: "/projects/demo/server/src"))
        XCTAssertFalse(row.belongs(to: "/projects/demo-other"))
        XCTAssertFalse(row.belongs(to: ""))
        XCTAssertTrue(row.searchText.contains("8080"))
    }

    func testInspectionIgnoresUnknownValuesAndHandlesUnpublishedPorts() throws {
        let raw = #"{"Id":"abc123","Config":{"Image":"app","Env":["SECRET=value"],"Labels":{"com.docker.compose.project":"demo"}},"State":{"ExitCode":0,"Health":{"Status":"healthy","Log":[]}},"NetworkSettings":{"Ports":{"80/tcp":[{"HostIp":"0.0.0.0","HostPort":"8080"}],"5432/tcp":null},"Networks":{"demo":{"IPAddress":"172.20.0.2"}}},"Mounts":[{"Type":"volume","Source":"/vol/data","Destination":"/data","RW":true}]}"#
        let value = try JSONDecoder().decode(DockerInspection.self, from: Data(raw.utf8))
        XCTAssertEqual(value.State?.Health?.Status, "healthy")
        XCTAssertEqual(value.NetworkSettings?.Ports?.count, 2)
        XCTAssertEqual(value.Mounts?.first?.Destination, "/data")
    }

    func testOnlyLocalPublishedTCPPortsOpenInBrowser() {
        let port = DockerInspection.Port(HostIp: "0.0.0.0", HostPort: "8080")
        XCTAssertEqual(port.browserURL(containerPort: "80/tcp", local: true)?.absoluteString, "http://127.0.0.1:8080")
        XCTAssertNil(port.browserURL(containerPort: "80/tcp", local: false))
        XCTAssertNil(port.browserURL(containerPort: "53/udp", local: true))
        XCTAssertNil(DockerInspection.Port(HostIp: "0.0.0.0", HostPort: "invalid").browserURL(containerPort: "80/tcp", local: true))
    }

    func testContextsArePassedToEachCommand() {
        XCTAssertEqual(DockerCommand.arguments(context: "staging", command: ["ps"]), ["docker", "--context", "staging", "ps"])
        XCTAssertEqual(DockerCommand.arguments(context: "", command: ["ps"]), ["docker", "ps"])
        XCTAssertTrue(DockerJSON.shellCommand(context: "dev's context", id: "abc123").contains("'dev'\\''s context'"))
    }

    func testResourceStatsDecode() throws {
        let value = try DockerJSON.lines(#"{"CPUPerc":"2.30%","MemUsage":"30MiB / 8GiB","MemPerc":"0.36%","NetIO":"1MB / 2MB","BlockIO":"0B / 3MB","PIDs":"7","Container":"abc123"}"#, as: DockerStats.self)
        XCTAssertEqual(value.first?.CPUPerc, "2.30%")
        XCTAssertEqual(value.first?.PIDs, "7")
    }

    @MainActor func testLogsUseDedicatedRestorableWorkspaceTabs() throws {
        let suite = "DockerWorkspaceTests." + UUID().uuidString
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let logs = ContainerLogWorkspace(key: "tabs", defaults: defaults)
        let first = logs.open(workspace: "workspace-a", context: "local", containerID: "abc123", name: "api")
        let again = logs.open(workspace: "workspace-a", context: "local", containerID: "abc123", name: "renamed-api")
        XCTAssertEqual(first.id, again.id)
        XCTAssertEqual(logs.tabs.count, 1)
        XCTAssertEqual(logs.active(in: "workspace-a")?.name, "renamed-api")
        XCTAssertNil(logs.active(in: "workspace-b"))
        let remote = logs.open(workspace: "workspace-a", context: "remote", containerID: "abc123", name: "remote-api")
        let other = logs.open(workspace: "workspace-b", context: "local", containerID: "abc123", name: "api")
        XCTAssertNotEqual(first.id, remote.id)
        XCTAssertNotEqual(first.id, other.id)
        XCTAssertEqual(logs.tabs(in: "workspace-a").count, 2)
        XCTAssertEqual(ContainerLogWorkspace(key: "tabs", defaults: defaults).tabs, logs.tabs)
        logs.activeID = remote.id
        logs.close(remote.id)
        XCTAssertEqual(logs.active(in: "workspace-a")?.id, first.id)
        logs.close(first.id)
        XCTAssertNil(logs.activeID)
        XCTAssertEqual(logs.tabs.count, 1)
        XCTAssertFalse(PlaneKind.addableCases.contains(.containerLogs))
    }
}
