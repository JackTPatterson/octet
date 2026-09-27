import SwiftUI

/// Settings › Other Macs: on or off, this Mac's name and key, the Macs it
/// has paired with (how much each may do), Macs nearby, pairing by address,
/// and giving agents the tools.
struct PeersSettingsGroup: View {
    @ObservedObject var settings: SettingsStore
    @ObservedObject private var center = PeerCenter.shared
    @State private var address = ""

    var body: some View {
        SettingsGroup(title: "Other Macs") {
            SettingsRow(
                title: "Talk to other Macs",
                detail: "Pair with Octet on your other Macs over this network, so agents on each can message the other's agents and hand them tasks. Nothing leaves your network: the Macs talk directly, encrypted. Each paired Mac asks before anything reaches an agent here, unless you allow it below."
            ) {
                Toggle("Talk to other Macs", isOn: $settings.values.peersEnabled).labelsHidden().toggleStyle(.switch)
            }
            SettingsDivider()
            SettingsRow(title: "This Mac's name", detail: "What your other Macs see. Leave empty for the computer's name.") {
                CommittedTextField(label: "This Mac's name", placeholder: Host.current().localizedName ?? "This Mac",
                                   value: $settings.values.peerName, width: 220, validate: { _ in nil })
            }
            if center.running {
                SettingsDivider()
                SettingsRow(title: "This Mac", detail: "Its key, to compare when pairing, and the port to type on a Mac that can't find it by itself.") {
                    Text("key \(center.identityFingerprint) · port \(center.port.map(String.init) ?? "…")")
                        .font(Theme.monoFont).foregroundStyle(Theme.textSecondary).textSelection(.enabled)
                }
                pairedRows
                nearbyRows
                SettingsDivider()
                SettingsRow(title: "Pair by address", detail: "For a Mac this one can't see on the network, like one on your tailnet: its address and port, e.g. studio.local:52100.") {
                    HStack(spacing: 6) {
                        TextField("host:port", text: $address)
                            .textFieldStyle(.roundedBorder).frame(width: 170)
                            .onSubmit { pairByAddress() }
                        OctetButton(title: "Pair", kind: .secondary, compact: true) { pairByAddress() }
                            .disabled(address.trimmingCharacters(in: .whitespaces).isEmpty)
                    }
                }
                if let status = center.pairingStatus {
                    Text(status).font(Theme.captionFont).foregroundStyle(Theme.textTertiary).padding(.horizontal, 14)
                }
                SettingsDivider()
                SettingsRow(title: "Let agents use other Macs",
                            detail: "Adds Octet's tools to Claude Code and Codex (list_agents, send_to_agent, read_agent, delegate_task, wait_for_task), so an agent can talk to agents on your paired Macs itself. Scripts can use octet-cli peer.") {
                    OctetButton(title: "Add to Agents…", kind: .secondary, compact: true) { PeerActions.installTools() }
                }
            }
        }
    }

    private func pairByAddress() {
        center.pair(address: address)
        address = ""
    }

    @ViewBuilder
    private var pairedRows: some View {
        ForEach(center.paired) { peer in
            SettingsDivider()
            HStack(spacing: 10) {
                Circle().fill(center.online.contains(peer.device) ? DiffReviewView.addedColor : Theme.textTertiary.opacity(0.5))
                    .frame(width: 7, height: 7)
                    .help(center.online.contains(peer.device) ? "Connected" : "Not connected now")
                VStack(alignment: .leading, spacing: 2) {
                    Text(peer.name).font(Theme.uiFont).foregroundStyle(Theme.textPrimary)
                    Text("key \(peer.fingerprint) · paired \(peer.paired.formatted(date: .abbreviated, time: .omitted))")
                        .font(Theme.captionFont).foregroundStyle(Theme.textTertiary)
                }
                Spacer()
                Picker("What \(peer.name) may do", selection: Binding(get: { peer.trust }, set: { center.setTrust($0, for: peer.device) })) {
                    ForEach(PeerTrust.allCases, id: \.self) { Text($0.title).tag($0) }
                }
                .labelsHidden().frame(width: 190)
                OctetButton(title: "Forget", kind: .ghost, compact: true) {
                    ConfirmCenter.shared.ask(title: "Forget \(peer.name)?",
                                             message: "It can't reach agents here until you pair again.",
                                             confirmTitle: "Forget", destructive: true) { _ in center.forget(peer.device) }
                }
            }
            .padding(.horizontal, 14).padding(.vertical, 8)
        }
    }

    @ViewBuilder
    private var nearbyRows: some View {
        ForEach(center.nearby) { found in
            SettingsDivider()
            HStack(spacing: 10) {
                Image(systemName: "desktopcomputer").foregroundStyle(Theme.textTertiary)
                Text(found.name).font(Theme.uiFont).foregroundStyle(Theme.textSecondary)
                Text("nearby").font(Theme.captionFont).foregroundStyle(Theme.textTertiary)
                Spacer()
                OctetButton(title: "Pair…", kind: .secondary, compact: true) { center.pair(with: found.endpoint, name: found.name) }
            }
            .padding(.horizontal, 14).padding(.vertical, 8)
        }
    }
}

/// Palette and Settings actions for other Macs.
@MainActor
enum PeerActions {
    /// Registers the MCP tools with the installed agents, after asking.
    static func installTools() {
        guard let cli = Bundle.main.url(forAuxiliaryExecutable: "octet-cli")?.path else {
            return ToastCenter.shared.fail(nil, "octet-cli is missing from the app bundle")
        }
        let installed = AgentDiscoveryStore.shared.agents.filter { $0.executablePath != nil }.map(\.id)
        let commands = PeerMCP.installCommands(cliPath: cli, agents: installed)
        guard !commands.isEmpty else {
            return ToastCenter.shared.info("Neither Claude Code nor Codex is installed")
        }
        ConfirmCenter.shared.ask(title: "Add the other-Macs tools to your agents?",
                                 message: "Runs these, which add an MCP server to each agent's own settings. Remove it with `claude mcp remove octet-peers` or `codex mcp remove octet-peers`.",
                                 detail: commands.joined(separator: "\n"), confirmTitle: "Add") { _ in
            let shell = ProcessInfo.processInfo.environment["SHELL"] ?? "/bin/zsh"
            let toast = ToastCenter.shared.progress("Adding the tools…")
            DispatchQueue.global(qos: .userInitiated).async {
                var failures: [String] = []
                for command in commands {
                    let process = Process()
                    process.executableURL = URL(fileURLWithPath: shell)
                    process.arguments = ["-lc", command]
                    let output = Pipe()
                    process.standardOutput = output
                    process.standardError = output
                    try? process.run()
                    let text = String(decoding: output.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
                    process.waitUntilExit()
                    // Already added counts as done.
                    if process.terminationStatus != 0, !text.lowercased().contains("already") {
                        failures.append(text.trimmingCharacters(in: .whitespacesAndNewlines))
                    }
                }
                DispatchQueue.main.async {
                    if failures.isEmpty {
                        ToastCenter.shared.succeed(toast, "Agents can use your other Macs", detail: "New agent sessions pick up the tools.")
                    } else {
                        ToastCenter.shared.fail(toast, "Couldn't add the tools everywhere", detail: failures.joined(separator: "\n"))
                    }
                }
            }
        }
    }
}
