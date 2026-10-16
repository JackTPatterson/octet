import SwiftUI

/// Settings › Other Macs, after T3 Code's Connections: on or off and this
/// Mac's name; a "This Mac" card with what another Mac needs to pair (its
/// name, version, address and key); the paired Macs, each with its status,
/// trust and a menu to forget it; and pairing through the Pair a Mac dialog.
struct PeersSettingsGroup: View {
    @ObservedObject var settings: SettingsStore
    @ObservedObject private var center = PeerCenter.shared
    @ObservedObject private var model = PeerPanelModel.shared
    @ObservedObject private var motion = MotionPreferences.shared

    var body: some View {
        // The settings page's own gap between groups.
        VStack(alignment: .leading, spacing: 32) {
            SettingsGroup(title: "Other Macs") {
                SettingsRow(
                    title: "Talk to other Macs",
                    detail: "Pair with Octet on your other Macs over this network, so agents on each can message the other's agents and hand them tasks. Nothing leaves your network: the Macs talk directly, encrypted. Each paired Mac asks before anything reaches an agent here, unless you allow it below."
                ) {
                    Toggle("Talk to other Macs", isOn: enabled).labelsHidden().toggleStyle(OctetSwitchStyle())
                }
                SettingsDivider()
                SettingsRow(title: "This Mac's name", detail: "What your other Macs see. Leave empty for the computer's name.") {
                    PeerNameField(placeholder: Host.current().localizedName ?? "This Mac", value: $settings.values.peerName)
                        .frame(width: 220)
                }
            }
            if center.running {
                thisMac
                pairedMacs
            }
        }
        .animation(motion.animation(.connections, .smooth(duration: 0.22)), value: center.paired.map(\.device))
        .onAppear(perform: loadOnline)
    }

    private var enabled: Binding<Bool> {
        #if DEBUG
        // The samples show Other Macs on without touching the real setting.
        if PeerSamples.active { return .constant(true) }
        #endif
        return $settings.values.peersEnabled
    }

    /// Reads each connected Mac's agents, for "Online · N agents".
    private func loadOnline() {
        for peer in center.paired where center.online.contains(peer.device) && model.agents[peer.name] == nil {
            model.loadAgents(peer.name)
        }
    }

    // MARK: This Mac

    /// T3 Code's "This machine" card: what another Mac needs to find and
    /// trust this one.
    private var thisMac: some View {
        SettingsGroup(title: "This Mac") {
            HStack(spacing: 10) {
                PeerMachineIcon(name: center.machineName, size: 15)
                VStack(alignment: .leading, spacing: 2) {
                    HStack(spacing: 6) {
                        Text(center.machineName).font(.system(size: 13, weight: .medium)).foregroundStyle(Theme.textPrimary)
                        PeerChip(text: "This Mac")
                    }
                    Text("Octet \(PeerCenter.appVersion) · Listening\(center.port.map { " on port \($0)" } ?? "")")
                        .font(.system(size: 11.5)).foregroundStyle(Theme.textTertiary)
                }
                Spacer(minLength: 8)
                PeerStatusDot(tone: .online, help: "Listening for your other Macs")
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 12)
            SettingsDivider()
            SettingsRow(title: "Address", detail: "Type this on a Mac that can't find this one by itself, like one on your tailnet.") {
                if let address = center.address {
                    OctetCopyText(text: address, help: "Copy this Mac's address")
                } else {
                    Text("…").font(Theme.monoFont).foregroundStyle(Theme.textTertiary)
                }
            }
            SettingsDivider()
            SettingsRow(title: "Key", detail: "Pairing shows a code on both Macs; this key is shown beside it, to be sure it's this Mac.") {
                OctetCopyText(text: center.identityFingerprint, help: "Copy this Mac's key")
            }
            SettingsDivider()
            SettingsRow(title: "How to pair",
                        detail: "On the other Mac, open Settings › Other Macs and choose Pair a Mac…, then pick \(center.machineName) or type its address. Both Macs show the same code; accept it on each.") {
                EmptyView()
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

    // MARK: Paired Macs

    private var pairedMacs: some View {
        SettingsGroup(title: "Paired Macs") {
            SettingsRow(title: "Pair a Mac", detail: pairDetail) {
                OctetButton(title: "Pair a Mac…", icon: "plus", kind: .primary, compact: true) {
                    PeerPairingModel.shared.present()
                }
            }
            if center.paired.isEmpty {
                SettingsDivider()
                PeerEmptyState(icon: "desktopcomputer", title: "No other Macs paired",
                               message: "Pair one to let agents here work with agents there.")
            }
            ForEach(center.paired) { peer in
                SettingsDivider()
                PeerSettingsRow(state: PeerMachineState(peer, center: center, model: model))
                    .transition(motion.animates(.connections) ? .opacity : .identity)
            }
        }
    }

    private var pairDetail: String {
        let nearby = center.nearby.count
        if nearby == 0 { return "Nearby Macs running Octet with Other Macs on show up in the dialog, or pair by address." }
        return nearby == 1 ? "1 Mac nearby isn't paired yet." : "\(nearby) Macs nearby aren't paired yet."
    }
}

/// One paired Mac, as T3 Code lists an environment: glyph, name and status
/// line, what it may do here, and its other actions behind a hover menu.
private struct PeerSettingsRow: View {
    let state: PeerMachineState
    @ObservedObject private var center = PeerCenter.shared
    @State private var hovered = false

    var body: some View {
        let peer = state.peer
        let status = state.status()
        HStack(spacing: 10) {
            PeerMachineIcon(name: peer.name, size: 14)
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 6) {
                    Text(peer.name).font(.system(size: 13, weight: .medium)).foregroundStyle(Theme.textPrimary).lineLimit(1)
                    PeerStatusDot(tone: status.tone, size: 6)
                }
                TimelineView(.periodic(from: .now, by: 60)) { context in
                    Text(state.status(now: context.date).text)
                        .font(.system(size: 11.5))
                        .foregroundStyle(status.tone.textColor)
                        .lineLimit(1)
                }
            }
            .help(state.details)
            Spacer(minLength: 8)
            OctetSelect(selection: Binding(get: { peer.trust }, set: { center.setTrust($0, for: peer.device) }),
                        options: PeerTrust.allCases.map { ($0, $0.title) }, width: 228)
                .accessibilityLabel("What \(peer.name) may do here")
            PeerRowMenu(label: "More for \(peer.name)", visible: hovered) {
                Button("Show Agents") {
                    PeerPanelModel.shared.focusMachine = peer.name
                    PeerWindow.show()
                }
                Button("New Task…") {
                    PeerPanelModel.shared.startTaskOn = peer.name
                    PeerWindow.show()
                }
                .disabled(!state.online)
                Button("Copy Key") {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(peer.fingerprint, forType: .string)
                }
                Divider()
                Button("Forget \(peer.name)…", role: .destructive) { forget(peer) }
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
        .background(hovered ? Theme.hover.opacity(0.35) : .clear)
        .contentShape(Rectangle())
        .onHover { inside in MotionPreferences.shared.perform(.connections, .easeOut(duration: 0.15)) { hovered = inside } }
    }

    private func forget(_ peer: PairedPeer) {
        ConfirmCenter.shared.ask(title: "Forget \(peer.name)?",
                                 message: "Its agents can't reach agents here, nor yours its, until you pair again.",
                                 confirmTitle: "Forget", destructive: true) { _ in
            MotionPreferences.shared.perform(.connections, .smooth(duration: 0.22)) { center.forget(peer.device) }
        }
    }
}

/// This Mac's name in an OctetTextField that applies only on Return or
/// when the field goes away: each change of name restarts Other Macs, so
/// it mustn't apply on every keystroke. (CommittedTextField does this with
/// a system field; this keeps Settings › Other Macs on Octet's controls.)
private struct PeerNameField: View {
    let placeholder: String
    @Binding var value: String
    @State private var draft = ""

    var body: some View {
        OctetTextField(placeholder: placeholder, text: $draft, onSubmit: commit)
            .onAppear { draft = value }
            .onChange(of: value) { _, new in if new != draft { draft = new } }
            .onDisappear(perform: commit)
            .help("Press Return to apply")
    }

    private func commit() {
        let trimmed = draft.trimmingCharacters(in: .whitespaces)
        if trimmed != value { value = trimmed }
    }
}
