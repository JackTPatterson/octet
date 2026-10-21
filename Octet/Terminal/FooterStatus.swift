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

/// Orca's compact utility group: awake, resources, ports and remote hosts.
/// Kept separate from the scrolling repository chips, so it stays at right.
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
        HStack(spacing: 9) {
            OctetDropdownAnchor(spec: OctetDropdownSpec(
                id: "footer-awake", options: [
                    .init(id: "off", title: "Off", detail: "Allow the Mac to sleep normally"),
                    .init(id: "plugged_in", title: "While agents work, on power", detail: "Allow sleep on battery"),
                    .init(id: "always", title: "While agents work, including battery", detail: "The display can still sleep")
                ], selected: settings.values.keepAwake.rawValue, select: { value in
                    if let mode = KeepAwake.Mode(rawValue: value) { settings.values.keepAwake = mode }
                }), state: window.chromeDropdowns) { _ in
                    chip {
                        glyph("cup.and.saucer")
                        if !compact { Text(awakeLabel) }
                        dot(sleep.isHolding)
                    }
                }
                .accessibilityLabel("Keep awake: \(awakeLabel), \(sleep.isHolding ? "active" : "inactive")")
                .help("Keep Mac awake while agents work · \(sleep.isHolding ? "Active" : "Inactive")")
            anchor("resources", compact: compact) {
                glyph("memorychip")
                if !compact {
                    Text(resources.bytes.map(ResourceFootprint.label) ?? "—").frame(minWidth: 60, alignment: .trailing)
                    Text("·").foregroundStyle(Theme.textTertiary)
                }
                TerminalPromptGlyph().stroke(style: StrokeStyle(lineWidth: 1.2, lineCap: .round, lineJoin: .round)).frame(width: 13, height: 13)
                Text("\(store.snapshot.panes.count)")
            }
            .accessibilityLabel("Resources: \(resources.bytes.map(ResourceFootprint.label) ?? "loading"), \(store.snapshot.panes.count) terminals")
            .help("Resident memory of Octet and known terminal process trees; terminal count across workspaces")
            anchor("ports", compact: compact) { glyph("powerplug"); Text("\(portCount)") }
                .accessibilityLabel("\(portCount) listening ports")
                .help("Listening web ports in Octet workspaces")
            anchor("hosts", compact: compact) {
                glyph(hosts.isEmpty ? "rectangle.slash" : "network")
                Text(compact ? "\(hosts.count)" : "\(hosts.count) \(hosts.count == 1 ? "host" : "hosts")")
                dot(!hosts.isEmpty)
            }
            .accessibilityLabel("\(hosts.count) SSH hosts")
            .help("Hosts with an interactive SSH session in Octet")
        }
        .font(Theme.interfaceFont(11).monospacedDigit())
        .foregroundStyle(Theme.textSecondary)
        .fixedSize()
    }

    private func anchor<Content: View>(_ kind: String, compact: Bool, @ViewBuilder content: @escaping () -> Content) -> some View {
        OctetDropdownAnchor(spec: OctetDropdownSpec(
            id: "footer-" + kind, options: [], selected: kind, select: { _ in },
            sizedPanel: { room, close in
                AnyView(FooterStatusPanel(kind: kind, store: store, resources: resources, maxHeight: room, close: close))
            }), state: window.chromeDropdowns) { _ in chip(content: content) }
    }

    private func chip<Content: View>(@ViewBuilder content: @escaping () -> Content) -> some View {
        StatusChip { content() }.font(Theme.interfaceFont(11).monospacedDigit())
    }
    private func glyph(_ symbol: String) -> some View {
        FooterUtilityGlyph(kind: symbol)
            .stroke(style: StrokeStyle(lineWidth: 1.1, lineCap: .round, lineJoin: .round))
            .frame(width: 13, height: 13)
    }
    private func dot(_ active: Bool) -> some View {
        Circle().fill(active ? Color(hex: AgentStateColor.done) : Theme.textTertiary.opacity(0.65)).frame(width: 5, height: 5)
    }
}

private struct TerminalPromptGlyph: Shape {
    func path(in rect: CGRect) -> Path {
        Path { path in
            path.move(to: CGPoint(x: rect.width * 0.12, y: rect.height * 0.2))
            path.addLine(to: CGPoint(x: rect.width * 0.45, y: rect.height * 0.5))
            path.addLine(to: CGPoint(x: rect.width * 0.12, y: rect.height * 0.8))
            path.move(to: CGPoint(x: rect.width * 0.55, y: rect.height * 0.8))
            path.addLine(to: CGPoint(x: rect.width * 0.9, y: rect.height * 0.8))
        }
    }
}

private struct FooterStatusPanel: View {
    let kind: String
    @ObservedObject var store: SessionStore
    @ObservedObject var resources: FooterResources
    let maxHeight: CGFloat
    let close: () -> Void
    @ObservedObject private var ports = PortsWatcher.shared
    @EnvironmentObject private var window: WindowContext
    @Environment(\.openURL) private var openURL

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(kind == "resources" ? "Resources" : kind == "ports" ? "Listening ports" : "Remote hosts")
                .font(Theme.headerFont).foregroundStyle(Theme.textPrimary)
            if kind == "resources" {
                Text(resources.bytes.map(ResourceFootprint.label) ?? "Measuring…").font(Theme.uiFont)
                Text("Resident memory of Octet and known terminal process trees. Shared pages may be counted by more than one process.")
                    .font(Theme.captionFont).foregroundStyle(Theme.textTertiary)
            }
            ScrollView {
                VStack(alignment: .leading, spacing: 6) {
                    if kind == "resources" {
                        if store.snapshot.panes.isEmpty { empty("No terminal sessions.") }
                        ForEach(store.snapshot.panes) { pane in
                            row(pane.terminalTitle ?? (pane.effectiveCwd.map(abbreviateHome) ?? "Terminal"), detail: pane.paneId) {
                                close(); window.focusAgent(paneId: pane.paneId)
                            }
                        }
                    } else if kind == "ports" {
                        let numbers = Array(Set(ports.byPane.values.flatMap { $0 })).sorted()
                        if numbers.isEmpty { empty("No listening web ports in Octet workspaces.") }
                        ForEach(numbers, id: \.self) { port in
                            ListeningPortRow(port: port, service: ports.services[port]) {
                                if let url = URL(string: "http://localhost:\(port)") { close(); openURL(url) }
                            }
                        }
                    } else {
                        let hosts = Array(Set(store.paneSSH.values.map(\.display))).sorted()
                        if hosts.isEmpty { empty("No active SSH hosts.") }
                        ForEach(hosts, id: \.self) { host in
                            row(host, detail: "SSH") {
                                if let pane = store.paneSSH.first(where: { $0.value.display == host })?.key {
                                    close(); window.focusAgent(paneId: pane)
                                }
                            }
                        }
                    }
                }.frame(maxWidth: .infinity, alignment: .leading)
            }
            .frame(height: min(listHeight, max(44, maxHeight - 150)))
        }
        .padding(12)
        .frame(width: 310)
        .octetGlass(cornerRadius: Theme.popoverRadius)
        .onExitCommand(perform: close)
    }

    private var listHeight: CGFloat {
        let count: Int
        switch kind {
        case "resources": count = store.snapshot.panes.count
        case "ports": count = Set(ports.byPane.values.flatMap { $0 }).count
        default: count = Set(store.paneSSH.values.map(\.display)).count
        }
        return min(210, max(44, CGFloat(count) * (kind == "ports" ? 36 : 30)))
    }

    private func empty(_ text: String) -> some View {
        Text(text).font(Theme.captionFont).foregroundStyle(Theme.textTertiary).padding(.vertical, 8)
    }
    private func row(_ title: String, detail: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack {
                Text(title).lineLimit(1).truncationMode(.middle)
                Spacer(minLength: 6)
                Text(detail).foregroundStyle(Theme.textTertiary).lineLimit(1)
            }.font(Theme.uiFont).padding(.vertical, 4).contentShape(Rectangle())
        }.buttonStyle(.plain)
    }
}

private struct ListeningPortRow: View {
    let port: Int
    let service: String?
    let action: () -> Void
    @State private var hovered = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: 9) {
                Text(verbatim: ":" + String(port))
                    .font(Theme.interfaceFont(11).monospacedDigit().weight(.medium))
                    .foregroundStyle(Theme.textPrimary)
                    .padding(.horizontal, 7)
                    .frame(height: 23)
                    .background(RoundedRectangle(cornerRadius: 6).fill(Theme.cardSelected))
                    .overlay(RoundedRectangle(cornerRadius: 6).strokeBorder(Theme.border, lineWidth: 1))
                Spacer(minLength: 4)
                if let logo = LanguageLogo(service: service, size: 14) {
                    logo.frame(width: 16, height: 16)
                } else {
                    OctetIcon("network", size: 14)
                        .foregroundStyle(Theme.textTertiary)
                        .frame(width: 16, height: 16)
                }
                Text(PreviewServiceName.display(service) ?? "Local server")
                    .font(Theme.uiFont)
                    .foregroundStyle(Theme.textSecondary)
                    .lineLimit(1)
            }
            .padding(.horizontal, 6)
            .frame(height: 30)
            .background(RoundedRectangle(cornerRadius: 7).fill(hovered ? Theme.hover : .clear))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hovered = $0 }
        .help("Open localhost:\(port)")
        .accessibilityLabel("Port \(port), \(PreviewServiceName.display(service) ?? "local server")")
    }
}

/// The small outline utilities used by Orca's footer, on a 24-point grid.
private struct FooterUtilityGlyph: Shape {
    let kind: String
    func path(in rect: CGRect) -> Path {
        var p = Path()
        func point(_ x: CGFloat, _ y: CGFloat) -> CGPoint { CGPoint(x: x * rect.width / 24, y: y * rect.height / 24) }
        func line(_ x: CGFloat, _ y: CGFloat, _ ex: CGFloat, _ ey: CGFloat) {
            p.move(to: point(x, y)); p.addLine(to: point(ex, ey))
        }
        func box(_ x: CGFloat, _ y: CGFloat, _ width: CGFloat, _ height: CGFloat, _ radius: CGFloat) {
            p.addRoundedRect(in: CGRect(origin: point(x, y), size: CGSize(width: width * rect.width / 24, height: height * rect.height / 24)),
                             cornerSize: CGSize(width: radius * rect.width / 24, height: radius * rect.height / 24))
        }
        switch kind {
        case "cup.and.saucer":
            box(3, 8, 14, 13, 2)
            p.move(to: point(17, 9)); p.addLine(to: point(20, 9))
            p.addQuadCurve(to: point(20, 16), control: point(25, 12.5)); p.addLine(to: point(17, 16))
            for x: CGFloat in [6, 10, 14] { line(x, 2, x, 4) }
        case "memorychip":
            box(2, 7, 20, 10, 2)
            for x: CGFloat in [6, 10, 14, 18] { line(x, 17, x, 20); line(x, 10, x, 13) }
        case "powerplug":
            box(5, 7, 14, 10, 3)
            line(8, 2, 8, 7); line(16, 2, 16, 7); line(12, 17, 12, 22)
        default:
            box(3, 4, 18, 16, 2)
            if kind == "rectangle.slash" { line(2, 2, 22, 22) }
            else {
                p.move(to: point(6, 8)); p.addLine(to: point(10, 12)); p.addLine(to: point(6, 16))
                line(13, 16, 17, 16)
            }
        }
        return p
    }
}
