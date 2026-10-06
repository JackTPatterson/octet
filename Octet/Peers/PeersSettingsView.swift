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
                SettingsRow(title: "Tools in your agents",
                            detail: "While this is on, Claude Code, Codex, Gemini, Qwen, OpenCode, Cursor and Copilot get list_agents, send_to_agent, read_agent, delegate_task and wait_for_task through the octet-peers MCP server, so an agent can talk to agents on your paired Macs itself. They're taken out when it's off. Scripts can use octet-cli peer.") {
                    OctetButton(title: "Add Again", kind: .secondary, compact: true) {
                        AgentMCPInstaller.shared.sync(server: PeerMCP.serverName, force: true)
                    }
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
