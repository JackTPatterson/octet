#if DEBUG
import AppKit
import Network
import SwiftUI

/// Verification hooks for the Other Macs screens: sample Macs, agents and
/// tasks in place of the network, so each state can be looked at without
/// pairing or talking to a real Mac. While a sample is showing, Other Macs
/// neither listens nor looks.
///
///     OCTET_OPEN_WINDOW=peers:settings        Settings › Other Macs
///     OCTET_OPEN_WINDOW=peers:settings:empty  …with nothing paired
///     OCTET_OPEN_WINDOW=peers:panel           the Peer window
///     OCTET_OPEN_WINDOW=peers:panel:empty     …with nothing paired
///     OCTET_OPEN_WINDOW=peers:panel:off       …with Other Macs off
///     OCTET_OPEN_WINDOW=peers:panel:tasks     …with the tasks and nearby Macs in view
///     OCTET_OPEN_WINDOW=peers:task            …with a new task form open
///     OCTET_OPEN_WINDOW=peers:pair[:connecting|:confirm|:incoming|:waiting|:paired|:failed]
@MainActor
enum PeerSamples {
    private(set) static var active = false
    private static var opened = false
    private static var settingsWindow: NSWindow?

    static func openIfAsked() {
        guard !opened, let open = ProcessInfo.processInfo.environment["OCTET_OPEN_WINDOW"], open.hasPrefix("peers:") else { return }
        opened = true
        active = true
        let parts = open.split(separator: ":").map(String.init)
        let what = parts.count > 1 ? parts[1] : "panel"
        let variant = parts.count > 2 ? parts[2] : ""
        load(empty: variant == "empty", running: variant != "off", onlyOffline: variant == "tasks")
        DispatchQueue.main.asyncAfter(deadline: .now() + 2.5) {
            switch what {
            case "settings": showSettings()
            case "task":
                PeerPanelModel.shared.startTaskOn = "Studio"
                PeerWindow.show()
            case "pair": showPairing(variant)
            default: PeerWindow.show()
            }
        }
    }

    private static func load(empty: Bool, running: Bool, onlyOffline: Bool) {
        let now = Date()
        func peer(_ name: String, _ trust: PeerTrust, _ seed: UInt8, pairedDaysAgo: Double) -> PairedPeer {
            PairedPeer(device: "sample-\(seed)", name: name, identity: Data(repeating: seed, count: 32), trust: trust,
                       lastHost: nil, lastPort: nil, paired: now.addingTimeInterval(-pairedDaysAgo * 86_400))
        }
        let studio = peer("Studio", .messages, 1, pairedDaysAgo: 40)
        let laptop = peer("J1PATTERSON-LT", .ask, 2, pairedDaysAgo: 12)
        let mini = peer("Mac mini", .messagesAndTasks, 3, pairedDaysAgo: 90)
        let old = peer("Office iMac", .ask, 4, pairedDaysAgo: 200)
        // "tasks" keeps only the offline Mac, so nothing opens and the
        // tasks and nearby lists are in view.
        let paired = empty ? [] : onlyOffline ? [laptop] : [studio, laptop, mini, old]
        let nearby = [DiscoveredPeer(name: "Jack's MacBook Air", device: "sample-9",
                                     endpoint: .hostPort(host: "127.0.0.1", port: 9))]
        PeerCenter.shared.showSample(
            paired: paired,
            online: empty ? [] : [studio.device, mini.device, old.device],
            nearby: nearby,
            lastSeen: [laptop.device: now.addingTimeInterval(-2 * 3600 - 300)],
            running: running)
        guard !empty else { return }
        func agent(_ id: String, _ kind: String, _ project: String, _ status: String) -> PeerProtocol.Agent {
            PeerProtocol.Agent(id: id, agent: kind, name: AgentBrand.forAgent(kind)?.displayName ?? kind,
                               project: project, folder: "~/code/\(project)", status: status)
        }
        PeerPanelModel.shared.showSample(
            agents: [
                "Studio": [agent("w1:p1", "claude", "octet", "working"), agent("w1:p3", "codex", "engine", "idle"),
                           agent("w2:p1", "claude", "site", "blocked")],
                "Mac mini": [agent("w1:p2", "codex", "lab-vault", "done")],
            ],
            versions: ["Studio": PeerCenter.appVersion, "Mac mini": PeerCenter.appVersion],
            latency: ["Studio": 0.012, "Mac mini": 0.034],
            issues: ["Office iMac": .versionTooOld],
            tasks: [
                .init(id: "a1", machine: "Studio", summary: "Run the engine tests and fix what fails", agent: "codex",
                      folder: "~/code/engine", started: now.addingTimeInterval(-185), status: "working"),
                .init(id: "a2", machine: "Mac mini", summary: "Summarise yesterday's recorder logs", agent: "claude",
                      folder: "~/code/lab-vault", started: now.addingTimeInterval(-3_900), status: "done",
                      result: "Read 4 log files.\nNo gaps in capture; 2 reconnects at 03:12 and 03:40.\nSummary written to notes/recorder.md."),
            ])
    }

    /// Settings › Other Macs on its own, at the settings page's width, so
    /// it can be checked whatever shape Settings itself takes.
    private static func showSettings() {
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 780, height: 900),
                              styleMask: [.titled, .closable, .resizable], backing: .buffered, defer: false)
        window.title = "Other Macs (Sample)"
        window.isReleasedWhenClosed = false
        let hosting = NSHostingController(rootView:
            ScrollView {
                PeersSettingsGroup(settings: SettingsStore.shared)
                    .padding(.horizontal, 24)
                    .padding(.vertical, 20)
                    .frame(maxWidth: 760, alignment: .leading)
                    .frame(maxWidth: .infinity)
            }
            .background(Theme.terminalBackground))
        // A scroll view has no size of its own to shrink the window to.
        hosting.sizingOptions = []
        window.contentViewController = hosting
        window.setContentSize(NSSize(width: 780, height: 900))
        window.center()
        settingsWindow = window
        NSApp.activate(ignoringOtherApps: true)
        window.makeKeyAndOrderFront(nil)
    }

    private static func showPairing(_ variant: String) {
        let model = PeerPairingModel.shared
        switch variant {
        case "connecting": model.showSample(.connecting(machine: "Studio"))
        case "confirm": model.showSample(.confirm(machine: "Studio", code: "482 913", fingerprint: "C41D-09AE", incoming: false))
        case "incoming": model.showSample(.confirm(machine: "J1PATTERSON-LT", code: "107 554", fingerprint: "9B2E-77F0", incoming: true))
        case "waiting": model.showSample(.waiting(machine: "Studio"))
        case "paired": model.showSample(.paired(machine: "Studio"))
        case "failed":
            model.showSample(.failed(machine: "Studio", reason: PeerPresentation.pairingFailure("The pairing was declined.", machine: "Studio")))
        default: model.showSample(.choose)
        }
    }
}
#endif
