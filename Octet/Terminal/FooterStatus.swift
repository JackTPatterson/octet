import SwiftUI

@MainActor
final class FooterResources: ObservableObject {
    @Published private(set) var bytes: UInt64?

    func refresh(roots: Set<Int>) async {
        let result = await Task.detached(priority: .utility) {
            let process = Process()
            process.executableURL = URL(fileURLWithPath: "/bin/ps")
            process.arguments = ["-axo", "pid=,ppid=,rss="]
            let pipe = Pipe()
            process.standardOutput = pipe
            process.standardError = FileHandle.nullDevice
            guard (try? process.run()) != nil else { return Optional<UInt64>.none }
            let data = pipe.fileHandleForReading.readDataToEndOfFile()
            process.waitUntilExit()
            guard process.terminationStatus == 0 else { return Optional<UInt64>.none }
            let rows = ResourceFootprint.parse(String(decoding: data, as: UTF8.self))
                .filter { $0.pid != Int(process.processIdentifier) }
            return Optional(ResourceFootprint.total(rows, roots: roots))
        }.value
        guard !Task.isCancelled else { return }
        if bytes != result { bytes = result }
    }
}

/// The status bar's utilities at the right: keeping the Mac awake, memory
/// and terminals, listening ports, and SSH hosts. Each is a quiet item in
/// one icon family that lifts under the pointer and opens a popover in the
/// conversation's style. Kept apart from the scrolling repository chips.
struct FooterStatus: View {
    @ObservedObject var store: SessionStore
    @ObservedObject private var settings = SettingsStore.shared
    @ObservedObject private var sleep = SleepGuard.shared
    @ObservedObject private var ports = PortsWatcher.shared
    @StateObject private var resources = FooterResources()
    @EnvironmentObject private var window: WindowContext

    private var hosts: [String] { Array(Set(store.paneSSH.values.map(\.display))).sorted() }
    private var portCount: Int { Set(ports.byPane.values.flatMap { $0 }).count }
    private var awakeLabel: String {
        switch settings.values.keepAwake {
        case .off: "Off"
        case .pluggedIn: "Auto"
        case .always: "Agents"
        }
    }

    var body: some View {
        ViewThatFits(in: .horizontal) {
            group(compact: false)
            group(compact: true)
        }
        .task {
            var tick = 0
            while !Task.isCancelled {
                if NSApp.isActive || tick % 6 == 0 {
                    let roots = Set(ports.shellPIDs.values).union([Int(getpid())])
                    await resources.refresh(roots: roots)
                }
                tick += 1
                do { try await Task.sleep(for: .seconds(5)) } catch { break }
            }
        }
    }

    private func group(compact: Bool) -> some View {
        HStack(spacing: 2) {
            anchor("awake") { open in
                FooterItem(symbol: "cup.and.saucer", open: open, active: sleep.isHolding) {
                    if !compact { Text(awakeLabel) }
                }
            }
            .accessibilityLabel("Keep awake: \(awakeLabel), \(sleep.isHolding ? "active" : "inactive")")
            .help("Keep the Mac awake while agents work · \(sleep.isHolding ? "Active" : "Inactive")")
            anchor("resources") { open in
                FooterItem(symbol: "memorychip", open: open) {
                    if !compact {
                        Text(resources.bytes.map(ResourceFootprint.label) ?? "—")
                        Image(systemName: "apple.terminal").font(.system(size: 11)).padding(.leading, 4)
                    }
                    Text("\(store.snapshot.panes.count)")
                }
            }
            .accessibilityLabel("Resources: \(resources.bytes.map(ResourceFootprint.label) ?? "loading"), \(store.snapshot.panes.count) terminals")
            .help("Memory of Octet and its terminals, and how many terminals are open")
            anchor("ports") { open in
                FooterItem(symbol: "powerplug", open: open, active: portCount > 0) { Text("\(portCount)") }
            }
            .accessibilityLabel("\(portCount) listening ports")
            .help("Local servers listening in Octet's terminals")
            anchor("hosts") { open in
                FooterItem(symbol: hosts.isEmpty ? "network.slash" : "network", open: open, active: !hosts.isEmpty) {
                    Text(compact ? "\(hosts.count)" : "\(hosts.count) \(hosts.count == 1 ? "host" : "hosts")")
                }
            }
            .accessibilityLabel("\(hosts.count) SSH hosts")
            .help("Machines with an SSH session open in Octet")
        }
        .fixedSize()
    }

    private func anchor<Label: View>(_ kind: String, @ViewBuilder label: @escaping (Bool) -> Label) -> some View {
        OctetDropdownAnchor(spec: OctetDropdownSpec(
            id: "footer-" + kind, options: [], selected: kind, select: { _ in },
            sizedPanel: { room, close in
                AnyView(FooterStatusPanel(kind: kind, store: store, resources: resources, maxHeight: room, close: close))
            }), state: window.chromeDropdowns, label: label)
    }
}

/// One utility in the status bar: its symbol, its figure, a green dot while
/// it's doing something, and a soft pill under the pointer or while open.
private struct FooterItem<Content: View>: View {
    let symbol: String
    let open: Bool
    var active: Bool?
    @ViewBuilder var content: () -> Content
    @State private var hovered = false

    var body: some View {
        HStack(spacing: 5) {
            Image(systemName: symbol).font(.system(size: 11.5))
            content()
            if let active {
                Circle()
                    .fill(active ? ChatStyle.added : ChatStyle.text.opacity(0.18))
                    .frame(width: 5, height: 5)
            }
        }
        .font(Theme.interfaceFont(11.5).monospacedDigit())
        .foregroundStyle(hovered || open ? ChatStyle.text : ChatStyle.mutedText)
        .padding(.horizontal, 7)
        .frame(height: 22)
        .background(RoundedRectangle(cornerRadius: 6, style: .continuous).fill(hovered || open ? ChatStyle.hover : .clear))
        .contentShape(Rectangle())
        .onHover { hovered = $0 }
        .animation(.easeOut(duration: 0.12), value: hovered)
    }
}

/// The popover behind each utility: a title with a one-line summary, then
/// rows to act on, or a word on why there are none.
private struct FooterStatusPanel: View {
    let kind: String
    @ObservedObject var store: SessionStore
    @ObservedObject var resources: FooterResources
    let maxHeight: CGFloat
    let close: () -> Void
    @ObservedObject private var ports = PortsWatcher.shared
    @ObservedObject private var settings = SettingsStore.shared
    @ObservedObject private var sleep = SleepGuard.shared
    @EnvironmentObject private var window: WindowContext
    @Environment(\.openURL) private var openURL

    private var portNumbers: [Int] { Array(Set(ports.byPane.values.flatMap { $0 })).sorted() }
    private var hosts: [String] { Array(Set(store.paneSSH.values.map(\.display))).sorted() }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
                .padding(.horizontal, 16)
                .padding(.top, 14)
                .padding(.bottom, 10)
            Rectangle().fill(ChatStyle.border).frame(height: 1)
            if kind == "awake" {
                awakeOptions.padding(6)
            } else {
                ScrollView {
                    VStack(alignment: .leading, spacing: 0) { rows }
                        .padding(6)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                .scrollIndicators(.never)
                .frame(height: min(listHeight, max(52, maxHeight - 120)))
            }
            if let note {
                Rectangle().fill(ChatStyle.border).frame(height: 1)
                Text(note)
                    .font(Theme.interfaceFont(11))
                    .foregroundStyle(ChatStyle.faintIcon)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.horizontal, 16)
                    .padding(.vertical, 10)
            }
        }
        .frame(width: 320)
        .chatPopover()
        .onExitCommand(perform: close)
    }

    private var header: some View {
        let (title, figure, summary): (String, String, String) = switch kind {
        case "awake":
            ("Keep Awake", awakeTitle, sleep.isHolding ? "Holding the Mac awake now, while agents work." : "Not holding the Mac awake right now.")
        case "resources":
            ("Resources", resources.bytes.map(ResourceFootprint.label) ?? "Measuring…",
             "\(store.snapshot.panes.count) \(store.snapshot.panes.count == 1 ? "terminal" : "terminals") across your workspaces")
        case "ports":
            ("Listening Ports", "\(portNumbers.count)",
             portNumbers.isEmpty ? "Nothing is serving right now." : "Local servers started in Octet's terminals")
        default:
            ("Remote Hosts", "\(hosts.count)",
             hosts.isEmpty ? "No SSH sessions open." : "Machines with an SSH session open in Octet")
        }
        return VStack(alignment: .leading, spacing: 4) {
            HStack(alignment: .firstTextBaseline) {
                Text(title).font(Theme.interfaceFont(13, weight: .semibold)).foregroundStyle(ChatStyle.text)
                Spacer(minLength: 8)
                Text(figure)
                    .font(Theme.interfaceFont(13, weight: .semibold).monospacedDigit())
                    .foregroundStyle(ChatStyle.text)
                    .contentTransition(.numericText())
            }
            Text(summary).font(ChatStyle.meta).foregroundStyle(ChatStyle.mutedText)
        }
    }

    private var awakeTitle: String {
        switch settings.values.keepAwake {
        case .off: "Off"
        case .pluggedIn: "On power"
        case .always: "Always"
        }
    }

    private var awakeOptions: some View {
        VStack(spacing: 0) {
            ForEach([(KeepAwake.Mode.off, "Off", "Let the Mac sleep as usual"),
                     (.pluggedIn, "While agents work, on power", "Sleeps on battery"),
                     (.always, "While agents work, on battery too", "The display can still sleep")], id: \.0) { mode, title, detail in
                FooterRow(icon: settings.values.keepAwake == mode ? "checkmark.circle.fill" : "circle",
                          iconTint: settings.values.keepAwake == mode ? ChatStyle.text : ChatStyle.faintIcon,
                          title: title, detail: detail) {
                    settings.values.keepAwake = mode
                }
            }
        }
    }

    @ViewBuilder private var rows: some View {
        switch kind {
        case "resources":
            if store.snapshot.panes.isEmpty { empty("No terminals open.") }
            ForEach(store.snapshot.panes) { pane in
                FooterRow(icon: "apple.terminal",
                          title: pane.terminalTitle ?? (pane.effectiveCwd.map { ($0 as NSString).lastPathComponent } ?? "Terminal"),
                          detail: pane.effectiveCwd.map(abbreviateHome) ?? pane.paneId, trailing: "Go to") {
                    close(); window.focusAgent(paneId: pane.paneId)
                }
            }
        case "ports":
            if portNumbers.isEmpty { empty("Start a dev server in a terminal and it shows up here.") }
            ForEach(portNumbers, id: \.self) { port in
                ListeningPortRow(port: port, service: ports.services[port]) {
                    if let url = URL(string: "http://localhost:\(port)") { close(); openURL(url) }
                }
            }
        default:
            if hosts.isEmpty { empty("Run ssh in a terminal and the host shows up here.") }
            ForEach(hosts, id: \.self) { host in
                FooterRow(icon: "network", title: host, detail: "SSH", trailing: "Go to") {
                    if let pane = store.paneSSH.first(where: { $0.value.display == host })?.key {
                        close(); window.focusAgent(paneId: pane)
                    }
                }
            }
        }
    }

    private var note: String? {
        switch kind {
        case "resources": "Resident memory of Octet and the processes its terminals started. Pages shared between processes can count more than once."
        case "awake": "The display can sleep either way; only the Mac is kept awake."
        default: nil
        }
    }

    private var listHeight: CGFloat {
        let count: Int = switch kind {
        case "resources": store.snapshot.panes.count
        case "ports": portNumbers.count
        default: hosts.count
        }
        return min(260, max(52, CGFloat(count) * 40 + 12))
    }

    private func empty(_ text: String) -> some View {
        Text(text)
            .font(ChatStyle.meta)
            .foregroundStyle(ChatStyle.mutedText)
            .fixedSize(horizontal: false, vertical: true)
            .padding(.horizontal, 10)
            .padding(.vertical, 10)
    }
}

/// A row in a status popover: an icon, a title over its detail, and what a
/// click does, shown under the pointer.
private struct FooterRow: View {
    let icon: String
    var iconTint: Color = ChatStyle.mutedText
    let title: String
    let detail: String
    var trailing: String?
    let action: () -> Void
    @State private var hovered = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: 10) {
                Image(systemName: icon).font(.system(size: 13)).foregroundStyle(iconTint).frame(width: 18)
                VStack(alignment: .leading, spacing: 1) {
                    Text(title).font(ChatStyle.metaMedium).foregroundStyle(ChatStyle.text)
                        .lineLimit(1).truncationMode(.middle)
                    Text(detail).font(Theme.interfaceFont(11)).foregroundStyle(ChatStyle.mutedText)
                        .lineLimit(1).truncationMode(.middle)
                }
                Spacer(minLength: 6)
                if let trailing {
                    HStack(spacing: 3) {
                        Text(trailing)
                        Image(systemName: "arrow.right").font(.system(size: 10))
                    }
                    .font(Theme.interfaceFont(11, weight: .medium))
                    .foregroundStyle(ChatStyle.secondaryText)
                    .opacity(hovered ? 1 : 0)
                }
            }
            .padding(.horizontal, 10)
            .frame(height: 40)
            .background(RoundedRectangle(cornerRadius: ChatStyle.controlRadius, style: .continuous)
                .fill(hovered ? ChatStyle.hover : .clear))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hovered = $0 }
    }
}

private struct ListeningPortRow: View {
    let port: Int
    let service: String?
    let action: () -> Void
    @State private var hovered = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: 10) {
                Group {
                    if let logo = LanguageLogo(service: service, size: 14) {
                        logo
                    } else {
                        Image(systemName: "server.rack").font(.system(size: 12)).foregroundStyle(ChatStyle.mutedText)
                    }
                }
                .frame(width: 18)
                VStack(alignment: .leading, spacing: 1) {
                    Text(PreviewServiceName.display(service) ?? "Local server")
                        .font(ChatStyle.metaMedium).foregroundStyle(ChatStyle.text).lineLimit(1)
                    Text(verbatim: "localhost:" + String(port))
                        .font(Theme.Text.mono(11)).foregroundStyle(ChatStyle.mutedText)
                }
                Spacer(minLength: 6)
                HStack(spacing: 3) {
                    Text("Open")
                    Image(systemName: "arrow.up.right").font(.system(size: 10))
                }
                .font(Theme.interfaceFont(11, weight: .medium))
                .foregroundStyle(ChatStyle.secondaryText)
                .opacity(hovered ? 1 : 0)
            }
            .padding(.horizontal, 10)
            .frame(height: 40)
            .background(RoundedRectangle(cornerRadius: ChatStyle.controlRadius, style: .continuous)
                .fill(hovered ? ChatStyle.hover : .clear))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hovered = $0 }
        .help("Open localhost:\(port)")
        .accessibilityLabel("Port \(port), \(PreviewServiceName.display(service) ?? "local server")")
    }
}
