import AppKit
import SwiftUI

/// The Peer window's content, after T3 Code's environment list: each
/// paired Mac as a card with its status line, its agents (to read, message
/// or hand a task to), the tasks given from here with their live status,
/// and pairing.
struct PeerPanel: View {
    let folder: String?
    @ObservedObject private var center = PeerCenter.shared
    @ObservedObject private var model = PeerPanelModel.shared
    @ObservedObject private var motion = MotionPreferences.shared
    @State private var open: Set<String> = []
    /// What's read from an agent, shown over the list.
    @State private var reading: (title: String, text: String, machine: String, agent: PeerProtocol.Agent)?
    @State private var messaging: String?
    @State private var message = ""
    @State private var tasking: String?
    @State private var taskAgent = "claude"
    @State private var taskFolder = ""
    @State private var taskText = ""
    @State private var hoveredAgent: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
            Rectangle().fill(Theme.divider).frame(height: 1)
            if let reading {
                output(reading)
                    .transition(motion.animates(.connections) ? .opacity.combined(with: .offset(x: 8)) : .identity)
            } else {
                ScrollView {
                    VStack(alignment: .leading, spacing: 16) {
                        if !center.running {
                            offState
                        } else {
                            macs
                            if !model.tasks.isEmpty { tasks }
                            if !center.nearby.isEmpty { nearby }
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(14)
                }
                .octetScrollIndicators()
                .transition(motion.animates(.connections) ? .opacity : .identity)
            }
        }
        .frame(minWidth: 400, maxWidth: .infinity, minHeight: 320, maxHeight: .infinity, alignment: .topLeading)
        .background(Theme.chrome)
        .animation(motion.animation(.connections, .smooth(duration: 0.22)), value: reading?.title)
        .onAppear {
            for peer in center.paired where center.online.contains(peer.device) {
                open.insert(peer.device)
                model.loadAgents(peer.name)
            }
            follow()
        }
        .onChange(of: model.focusMachine) { _, _ in follow() }
        .onChange(of: model.startTaskOn) { _, _ in follow() }
    }

    /// Opens what the menu asked for.
    private func follow() {
        if let machine = model.focusMachine, let peer = center.paired.first(where: { $0.name == machine }) {
            reading = nil
            open.insert(peer.device)
            model.loadAgents(machine)
            model.focusMachine = nil
        }
        if let machine = model.startTaskOn {
            reading = nil
            if let peer = center.paired.first(where: { $0.name == machine }) { open.insert(peer.device) }
            beginTask(on: machine)
            model.startTaskOn = nil
        }
    }

    private func beginTask(on machine: String) {
        MotionPreferences.shared.perform(.connections, .smooth(duration: 0.22)) {
            tasking = machine
        }
        taskFolder = folder.map { ($0 as NSString).abbreviatingWithTildeInPath } ?? "~/"
        taskText = ""
        model.clearTaskError(machine)
    }

    // MARK: Header

    private var header: some View {
        HStack(spacing: 8) {
            Text("Other Macs").font(.system(size: 13, weight: .semibold)).foregroundStyle(Theme.textPrimary)
            HStack(spacing: 5) {
                PeerStatusDot(tone: center.running ? .online : .idle, size: 6)
                Text(center.machineName).font(Theme.captionFont).foregroundStyle(Theme.textSecondary).lineLimit(1)
            }
            .padding(.horizontal, 6)
            .frame(height: 20)
            .background(RoundedRectangle(cornerRadius: 6).fill(Theme.hover.opacity(0.6)))
            .help("This Mac, as your other Macs see it")
            Spacer(minLength: 6)
            if center.running {
                OctetButton(title: "Pair a Mac…", icon: "plus", kind: .ghost, compact: true) {
                    PeerPairingModel.shared.present()
                }
            }
            OctetIconButton(icon: "gearshape", help: "Other Macs Settings") {
                PluginSettingsOpener.show(pluginId: "other-macs")
            }
        }
        .padding(.horizontal, 14)
        .frame(height: 44)
    }

    private var offState: some View {
        PeerEmptyState(icon: "wifi.slash", title: "Other Macs is off",
                       message: "Turn on Talk to Other Macs in Settings to pair this Mac with your others.") {
            OctetButton(title: "Open Settings", kind: .secondary, compact: true) {
                PluginSettingsOpener.show(pluginId: "other-macs")
            }
        }
        .frame(maxWidth: .infinity, minHeight: 240)
    }

    // MARK: Paired Macs

    @ViewBuilder private var macs: some View {
        if center.paired.isEmpty {
            PeerEmptyState(icon: "desktopcomputer", title: "No other Macs paired",
                           message: "Pair one to let agents here work with agents there.") {
                OctetButton(title: "Pair a Mac…", icon: "plus", kind: .primary, compact: true) {
                    PeerPairingModel.shared.present()
                }
            }
            .background(RoundedRectangle(cornerRadius: 12).fill(Theme.card.opacity(0.55)))
            .overlay(RoundedRectangle(cornerRadius: 12).strokeBorder(Theme.border.opacity(0.7), lineWidth: 1))
        } else {
            VStack(alignment: .leading, spacing: 8) {
                PeerSectionHeader(title: "Paired Macs")
                ForEach(center.paired) { peer in machineCard(PeerMachineState(peer, center: center, model: model)) }
            }
        }
    }

    private func machineCard(_ state: PeerMachineState) -> some View {
        let peer = state.peer
        let isOpen = open.contains(peer.device)
        let status = state.status()
        return VStack(alignment: .leading, spacing: 0) {
            Button {
                MotionPreferences.shared.perform(.connections, .smooth(duration: 0.22)) {
                    if open.remove(peer.device) == nil { open.insert(peer.device) }
                }
                if open.contains(peer.device) { model.loadAgents(peer.name) }
            } label: {
                HStack(spacing: 9) {
                    PeerMachineIcon(name: peer.name)
                    VStack(alignment: .leading, spacing: 2) {
                        HStack(spacing: 6) {
                            Text(peer.name).font(Theme.uiFontMedium).foregroundStyle(Theme.textPrimary).lineLimit(1)
                            PeerStatusDot(tone: status.tone, size: 6)
                        }
                        Text(statusLine(state, status))
                            .font(Theme.captionFont)
                            .foregroundStyle(status.tone.textColor)
                            .lineLimit(1)
                    }
                    Spacer(minLength: 4)
                    if model.loading.contains(peer.name) { ProgressView().controlSize(.mini) }
                    OctetIcon("chevron.right", size: 10)
                        .foregroundStyle(Theme.textTertiary)
                        .rotationEffect(.degrees(isOpen ? 90 : 0))
                }
                .padding(.horizontal, 12)
                .frame(minHeight: 46)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .help(state.details)
            if isOpen {
                Rectangle().fill(Theme.divider.opacity(0.8)).frame(height: 1)
                machineDetail(state)
                    .padding(12)
                    .transition(motion.animates(.connections) ? .opacity.combined(with: .offset(y: -4)) : .identity)
            }
        }
        .background(RoundedRectangle(cornerRadius: 12).fill(Theme.card.opacity(0.55)))
        .overlay(RoundedRectangle(cornerRadius: 12).strokeBorder(Theme.border.opacity(0.7), lineWidth: 1))
        .clipShape(RoundedRectangle(cornerRadius: 12))
    }

    /// The status, with the version and round trip when they're known.
    private func statusLine(_ state: PeerMachineState, _ status: PeerPresentation.Status) -> String {
        var parts = [status.text]
        if state.online, state.issue == nil, let latency = state.latency { parts.append(PeerPresentation.latency(latency)) }
        return parts.joined(separator: " · ")
    }

    @ViewBuilder private func machineDetail(_ state: PeerMachineState) -> some View {
        let machine = state.peer.name
        VStack(alignment: .leading, spacing: 10) {
            if let issue = state.issue, !(issue == .offline && state.online) {
                PeerIssueBanner(issue: issue, machine: machine) { model.loadAgents(machine) }
            } else if !state.online {
                PeerIssueBanner(issue: .offline, machine: machine) { model.loadAgents(machine) }
            }
            if let agents = state.agents, state.issue == nil {
                if agents.isEmpty {
                    Text("No agents running on \(machine). Start one with a task below.")
                        .font(Theme.captionFont).foregroundStyle(Theme.textTertiary)
                } else {
                    VStack(spacing: 2) {
                        ForEach(agents, id: \.id) { agent in agentRow(agent, machine: machine) }
                    }
                }
            }
            if tasking == machine {
                taskForm(machine)
                    .transition(motion.animates(.connections) ? .opacity.combined(with: .offset(y: -4)) : .identity)
            } else {
                HStack(spacing: 6) {
                    OctetButton(title: "New Task on \(machine)…", icon: "plus", kind: .secondary, compact: true) {
                        beginTask(on: machine)
                    }
                    OctetButton(title: "Refresh", icon: "arrow.clockwise", kind: .ghost, compact: true) { model.loadAgents(machine) }
                    Spacer()
                }
                .disabled(!state.online)
            }
        }
    }

    private func agentRow(_ agent: PeerProtocol.Agent, machine: String) -> some View {
        let key = machine + "\u{0}" + agent.id
        let hovered = hoveredAgent == key || messaging == key
        return VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 8) {
                Group {
                    if let brand = AgentBrand.forAgent(agent.agent) { AgentLogo(brand: brand, size: 14) }
                    else { OctetIcon("sparkle", size: 14).foregroundStyle(Theme.textSecondary) }
                }
                .frame(width: 18)
                VStack(alignment: .leading, spacing: 1) {
                    Text(agent.name).font(Theme.uiFont).foregroundStyle(Theme.textPrimary).lineLimit(1)
                    Text(agent.project.isEmpty ? agent.folder : agent.project)
                        .font(Theme.captionFont).foregroundStyle(Theme.textTertiary).lineLimit(1)
                        .help(agent.folder)
                }
                Spacer(minLength: 4)
                if hovered {
                    HStack(spacing: 2) {
                        OctetButton(title: "Read", icon: "eye", kind: .ghost, compact: true) {
                            model.read(agent, on: machine) { text in
                                reading = ("\(agent.name) on \(machine)", text, machine, agent)
                            }
                        }
                        OctetButton(title: "Message", icon: "message", kind: .ghost, compact: true) {
                            MotionPreferences.shared.perform(.connections, .smooth(duration: 0.2)) {
                                messaging = messaging == key ? nil : key
                            }
                            message = ""
                        }
                    }
                    .transition(.opacity)
                } else {
                    agentStatus(agent.status)
                }
            }
            if messaging == key {
                HStack(spacing: 6) {
                    OctetTextField(placeholder: "Message for \(agent.name)", text: $message) { sendMessage(agent, machine) }
                    OctetButton(title: "Send", kind: .primary, compact: true) { sendMessage(agent, machine) }
                        .disabled(message.trimmingCharacters(in: .whitespaces).isEmpty)
                }
                .padding(.leading, 26)
            }
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 6)
        .background(RoundedRectangle(cornerRadius: Theme.controlRadius).fill(hoveredAgent == key ? Theme.hover.opacity(0.6) : .clear))
        .contentShape(Rectangle())
        .onHover { inside in
            MotionPreferences.shared.perform(.connections, .easeOut(duration: 0.15)) {
                hoveredAgent = inside ? key : (hoveredAgent == key ? nil : hoveredAgent)
            }
        }
    }

    private func agentStatus(_ raw: String) -> some View {
        HStack(spacing: 5) {
            AgentStateGlyph(status: EngineAgentStatus(rawValue: raw) ?? .unknown, size: 9)
            Text(PeerPresentation.agentStatus(raw)).font(Theme.captionFont).foregroundStyle(Theme.textTertiary)
        }
    }

    private func sendMessage(_ agent: PeerProtocol.Agent, _ machine: String) {
        let text = message.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return }
        model.send(text, to: agent, on: machine)
        message = ""
        messaging = nil
    }

    private func taskForm(_ machine: String) -> some View {
        let starting = model.starting.contains(machine)
        let ready = !taskText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            && !taskFolder.trimmingCharacters(in: .whitespaces).isEmpty
        return VStack(alignment: .leading, spacing: 9) {
            Text("New Task on \(machine)").font(Theme.uiFontMedium).foregroundStyle(Theme.textPrimary)
            OctetSegmented(selection: $taskAgent, items: [("claude", "Claude Code"), ("codex", "Codex")])
            VStack(alignment: .leading, spacing: 4) {
                Text("Folder on \(machine)").font(Theme.captionFont).foregroundStyle(Theme.textTertiary)
                OctetTextField(placeholder: "~/code/app", text: $taskFolder)
            }
            OctetTextEditor(placeholder: "What should it do?", text: $taskText, minHeight: 64, maxHeight: 140)
            if let error = model.taskErrors[machine] {
                Text(error).font(Theme.captionFont).foregroundStyle(Theme.danger).fixedSize(horizontal: false, vertical: true)
            }
            HStack(spacing: 8) {
                if starting {
                    ProgressView().controlSize(.mini)
                    Text("Waiting for \(machine) to take it…").font(Theme.captionFont).foregroundStyle(Theme.textTertiary)
                } else {
                    Text("It runs in a tab there; the answer comes back here.")
                        .font(Theme.captionFont).foregroundStyle(Theme.textTertiary)
                }
                Spacer(minLength: 6)
                OctetButton(title: "Cancel", kind: .ghost, compact: true) {
                    MotionPreferences.shared.perform(.connections, .smooth(duration: 0.2)) { tasking = nil }
                }
                OctetButton(title: starting ? "Starting…" : "Start", kind: .primary, compact: true) {
                    model.delegate(taskText, agent: taskAgent, folder: taskFolder, on: machine) { started in
                        guard started else { return }
                        MotionPreferences.shared.perform(.connections, .smooth(duration: 0.2)) { tasking = nil }
                    }
                }
                .keyboardShortcut(.defaultAction)
                .disabled(!ready || starting)
            }
        }
        .padding(12)
        .background(RoundedRectangle(cornerRadius: 10).fill(Theme.terminalBackground.opacity(0.35)))
        .overlay(RoundedRectangle(cornerRadius: 10).strokeBorder(Theme.border.opacity(0.7), lineWidth: 1))
    }

    // MARK: Tasks given from here

    private var tasks: some View {
        VStack(alignment: .leading, spacing: 8) {
            PeerSectionHeader(title: "Tasks") {
                if model.tasks.contains(where: { $0.status != "working" }) {
                    OctetButton(title: "Clear Finished", kind: .ghost, compact: true) { model.clearFinished() }
                }
            }
            VStack(spacing: 0) {
                ForEach(Array(model.tasks.enumerated()), id: \.element.id) { index, task in
                    if index > 0 { SettingsDivider() }
                    PeerTaskRow(task: task)
                }
            }
            .background(RoundedRectangle(cornerRadius: 12).fill(Theme.card.opacity(0.55)))
            .overlay(RoundedRectangle(cornerRadius: 12).strokeBorder(Theme.border.opacity(0.7), lineWidth: 1))
            .clipShape(RoundedRectangle(cornerRadius: 12))
        }
    }

    // MARK: Nearby

    private var nearby: some View {
        VStack(alignment: .leading, spacing: 8) {
            PeerSectionHeader(title: "Nearby, Not Paired")
            VStack(spacing: 0) {
                ForEach(Array(center.nearby.enumerated()), id: \.element.id) { index, found in
                    if index > 0 { SettingsDivider() }
                    HStack(spacing: 9) {
                        PeerMachineIcon(name: found.name)
                        Text(found.name).font(Theme.uiFont).foregroundStyle(Theme.textSecondary).lineLimit(1)
                        Spacer()
                        OctetButton(title: "Pair…", kind: .secondary, compact: true) {
                            PeerPairingModel.shared.present()
                            PeerPairingModel.shared.pair(with: found)
                        }
                    }
                    .padding(.horizontal, 12)
                    .frame(height: 40)
                }
            }
            .background(RoundedRectangle(cornerRadius: 12).fill(Theme.card.opacity(0.55)))
            .overlay(RoundedRectangle(cornerRadius: 12).strokeBorder(Theme.border.opacity(0.7), lineWidth: 1))
            .clipShape(RoundedRectangle(cornerRadius: 12))
        }
    }

    // MARK: Reading an agent

    private func output(_ shown: (title: String, text: String, machine: String, agent: PeerProtocol.Agent)) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 6) {
                OctetIconButton(icon: "chevron.left", help: "Back") { reading = nil }
                if let brand = AgentBrand.forAgent(shown.agent.agent) { AgentLogo(brand: brand, size: 13) }
                Text(shown.title).font(Theme.uiFontMedium).foregroundStyle(Theme.textPrimary).lineLimit(1)
                Spacer()
                OctetButton(title: "Refresh", icon: "arrow.clockwise", kind: .ghost, compact: true) {
                    model.read(shown.agent, on: shown.machine) { text in reading = (shown.title, text, shown.machine, shown.agent) }
                }
            }
            ScrollView {
                Text(shown.text)
                    .font(Theme.monoFont)
                    .foregroundStyle(Theme.textSecondary)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .textSelection(.enabled)
                    .padding(10)
            }
            .octetScrollIndicators()
            .frame(maxHeight: .infinity)
            .background(RoundedRectangle(cornerRadius: 10).fill(Theme.terminalBackground))
            .overlay(RoundedRectangle(cornerRadius: 10).strokeBorder(Theme.border.opacity(0.7), lineWidth: 1))
        }
        .padding(14)
    }
}

/// A task given from here: what it was, where, its live status and, once
/// it finishes, the end of the agent's screen to read.
private struct PeerTaskRow: View {
    let task: PeerPanelModel.Task
    @State private var expanded = false

    var body: some View {
        let status = PeerPresentation.taskStatus(task.status)
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 8) {
                Group {
                    if task.status == "working" {
                        ProgressView().controlSize(.mini)
                    } else {
                        PeerStatusDot(tone: status.tone, size: 6)
                    }
                }
                .frame(width: 16)
                if let brand = AgentBrand.forAgent(task.agent) { AgentLogo(brand: brand, size: 12) }
                VStack(alignment: .leading, spacing: 1) {
                    Text(task.summary).font(Theme.uiFont).foregroundStyle(Theme.textPrimary).lineLimit(1)
                    TimelineView(.periodic(from: .now, by: 30)) { context in
                        Text("\(task.machine) · \(status.text) · \(PeerPresentation.elapsed(since: task.started, now: context.date))")
                            .font(Theme.captionFont).foregroundStyle(status.tone == .online ? Theme.textTertiary : status.tone.textColor)
                            .lineLimit(1)
                    }
                }
                Spacer(minLength: 4)
                if let result = task.result, !result.isEmpty {
                    OctetIcon("chevron.right", size: 10)
                        .foregroundStyle(Theme.textTertiary)
                        .rotationEffect(.degrees(expanded ? 90 : 0))
                }
            }
            .contentShape(Rectangle())
            .onTapGesture {
                guard task.result?.isEmpty == false else { return }
                MotionPreferences.shared.perform(.connections, .smooth(duration: 0.2)) { expanded.toggle() }
            }
            if expanded, let result = task.result, !result.isEmpty {
                ScrollView {
                    Text(result).font(Theme.monoFont).foregroundStyle(Theme.textSecondary)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .textSelection(.enabled)
                        .padding(8)
                }
                .frame(maxHeight: 180)
                .background(RoundedRectangle(cornerRadius: 8).fill(Theme.terminalBackground))
                .transition(.opacity)
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 9)
    }
}
