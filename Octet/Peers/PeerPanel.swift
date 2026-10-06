import AppKit
import SwiftUI

/// What the Peer panel remembers while it's closed: each Mac's agents as
/// last read, and the tasks given from here with their answers.
@MainActor
final class PeerPanelModel: ObservableObject {
    static let shared = PeerPanelModel()

    struct Task: Identifiable {
        let id: String
        let machine: String
        let summary: String
        var status: String
        var result: String?
    }

    @Published private(set) var agents: [String: [PeerProtocol.Agent]] = [:]
    @Published private(set) var loading: Set<String> = []
    @Published private(set) var errors: [String: String] = [:]
    @Published private(set) var tasks: [Task] = []
    /// What the menu asked the window to show: a Mac to open, and whether
    /// to start a task there.
    @Published var focusMachine: String?
    @Published var startTaskOn: String?

    /// Reads which agents run on `machine`.
    func loadAgents(_ machine: String) {
        loading.insert(machine)
        PeerCenter.shared.request(.agents, ["machine": machine]) { [weak self] answer in
            guard let self else { return }
            self.loading.remove(machine)
            if let error = answer["error"] as? String {
                self.errors[machine] = error
                return
            }
            self.errors[machine] = nil
            self.agents[machine] = ((answer["result"] as? [String: Any])?["agents"] as? [[String: Any]] ?? [])
                .compactMap(PeerProtocol.Agent.init)
        }
    }

    func send(_ text: String, to agent: PeerProtocol.Agent, on machine: String) {
        PeerCenter.shared.request(.send, ["machine": machine, "agent": agent.id, "text": text]) { answer in
            if let error = answer["error"] as? String {
                ToastCenter.shared.fail(nil, "Couldn't message \(agent.name) on \(machine)", detail: error)
            } else {
                ToastCenter.shared.info("Sent to \(agent.name) on \(machine)")
            }
        }
    }

    func read(_ agent: PeerProtocol.Agent, on machine: String, lines: Int = 120, done: @escaping (String) -> Void) {
        PeerCenter.shared.request(.read, ["machine": machine, "agent": agent.id, "lines": lines]) { answer in
            if let error = answer["error"] as? String { return done("Couldn't read it: \(error)") }
            let text = (answer["result"] as? [String: Any])?["text"] as? String ?? ""
            done(text.isEmpty ? "Nothing on screen yet." : text)
        }
    }

    /// Starts an agent on `machine` with `task`, then waits for its answer.
    func delegate(_ task: String, agent: String, folder: String, on machine: String) {
        PeerCenter.shared.request(.delegate, ["machine": machine, "agent_type": agent, "folder": folder, "task": task]) { [weak self] answer in
            guard let self else { return }
            if let error = answer["error"] as? String {
                return ToastCenter.shared.fail(nil, "\(machine) didn't take the task", detail: error)
            }
            guard let id = (answer["result"] as? [String: Any])?["task"] as? String else { return }
            self.tasks.insert(Task(id: id, machine: machine, summary: task, status: "working"), at: 0)
            self.wait(for: id)
        }
    }

    private func wait(for id: String) {
        PeerCenter.shared.request(.wait, ["task": id, "timeout_seconds": 3600]) { [weak self] answer in
            guard let self, let index = self.tasks.firstIndex(where: { $0.id == id }) else { return }
            let result = answer["result"] as? [String: Any] ?? [:]
            self.tasks[index].status = result["status"] as? String ?? self.tasks[index].status
            self.tasks[index].result = result["result"] as? String ?? (answer["error"] as? String)
            if result["note"] != nil { self.wait(for: id) }  // Still going: keep waiting.
        }
    }

    func clearFinished() { tasks.removeAll { $0.status != "working" } }
}

/// The Peer window's content: your paired Macs and their agents, to read,
/// message and hand tasks to, the tasks given from here, and pairing.
struct PeerPanel: View {
    let folder: String?
    @ObservedObject private var center = PeerCenter.shared
    @ObservedObject private var model = PeerPanelModel.shared
    @State private var open: Set<String> = []
    @State private var address = ""
    /// What's read from an agent, shown over the list.
    @State private var reading: (title: String, text: String, machine: String, agent: PeerProtocol.Agent)?
    @State private var messaging: String?
    @State private var message = ""
    @State private var tasking: String?
    @State private var taskAgent = "claude"
    @State private var taskFolder = ""
    @State private var taskText = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            header
            if let reading {
                output(reading)
            } else {
                ScrollView {
                    VStack(alignment: .leading, spacing: 10) {
                        if !center.running {
                            note("Other Macs is starting, or couldn't start. Check Settings › Plugins.")
                        }
                        macs
                        if !model.tasks.isEmpty { tasks }
                        pairing
                    }
                }
            }
        }
        .padding(12)
        .frame(minWidth: 380, maxWidth: .infinity, minHeight: 300, maxHeight: .infinity, alignment: .topLeading)
        .background(Theme.chrome)
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
            tasking = machine
            taskFolder = folder.map { ($0 as NSString).abbreviatingWithTildeInPath } ?? "~/"
            taskText = ""
            model.startTaskOn = nil
        }
    }

    private var header: some View {
        HStack(spacing: 6) {
            Image(systemName: "desktopcomputer").font(.system(size: 12)).foregroundStyle(Theme.textSecondary)
            Text("Peer").font(Theme.uiFontMedium).foregroundStyle(Theme.textPrimary)
            Text("this Mac: \(center.machineName)").font(Theme.captionFont).foregroundStyle(Theme.textTertiary).lineLimit(1)
            Spacer(minLength: 6)
            Button {
                PluginSettingsOpener.show(pluginId: "other-macs")
            } label: { Image(systemName: "gearshape") }
                .buttonStyle(.plain).foregroundStyle(Theme.textSecondary)
                .help("Other Macs settings")
        }
    }

    // MARK: Paired Macs

    @ViewBuilder private var macs: some View {
        if center.paired.isEmpty {
            note("No Macs paired yet. Pair one below: open Octet there with Other Macs on, and it shows up as nearby.")
        }
        ForEach(center.paired) { peer in
            let online = center.online.contains(peer.device)
            VStack(alignment: .leading, spacing: 6) {
                Button {
                    if open.remove(peer.device) == nil {
                        open.insert(peer.device)
                        model.loadAgents(peer.name)
                    }
                } label: {
                    HStack(spacing: 7) {
                        Circle().fill(online ? Color(hex: AgentStateColor.done) : Theme.textTertiary.opacity(0.5)).frame(width: 7, height: 7)
                        Text(peer.name).font(Theme.uiFontMedium).foregroundStyle(Theme.textPrimary)
                        Text(online ? "connected" : "not connected").font(Theme.captionFont).foregroundStyle(Theme.textTertiary)
                        Spacer(minLength: 4)
                        if model.loading.contains(peer.name) { ProgressView().controlSize(.mini) }
                        OctetIcon("chevron.right", size: 10).foregroundStyle(Theme.textTertiary)
                            .rotationEffect(.degrees(open.contains(peer.device) ? 90 : 0))
                    }
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                if open.contains(peer.device) {
                    machineDetail(peer.name, online: online)
                }
            }
            .padding(8)
            .background(Theme.card)
            .clipShape(RoundedRectangle(cornerRadius: 6))
        }
    }

    @ViewBuilder private func machineDetail(_ machine: String, online: Bool) -> some View {
        if let error = model.errors[machine] {
            note(error)
        } else if let agents = model.agents[machine] {
            if agents.isEmpty { note("No agents running there.") }
            ForEach(agents, id: \.id) { agent in agentRow(agent, machine: machine) }
        }
        if tasking == machine {
            taskForm(machine)
        } else {
            HStack(spacing: 6) {
                OctetButton(title: "New Task…", icon: "plus", kind: .secondary, compact: true) {
                    tasking = machine
                    taskFolder = folder.map { ($0 as NSString).abbreviatingWithTildeInPath } ?? "~/"
                    taskText = ""
                }
                OctetButton(title: "Refresh", kind: .ghost, compact: true) { model.loadAgents(machine) }
            }
            .disabled(!online)
        }
    }

    private func agentRow(_ agent: PeerProtocol.Agent, machine: String) -> some View {
        let key = machine + "\u{0}" + agent.id
        return VStack(alignment: .leading, spacing: 5) {
            HStack(spacing: 6) {
                if let brand = AgentBrand.forAgent(agent.agent) { AgentLogo(brand: brand, size: 12) }
                VStack(alignment: .leading, spacing: 1) {
                    Text(agent.name).font(Theme.uiFont).foregroundStyle(Theme.textPrimary).lineLimit(1)
                    Text("\(agent.project) · \(agent.status)").font(Theme.captionFont).foregroundStyle(Theme.textTertiary).lineLimit(1)
                }
                Spacer(minLength: 4)
                Button("Read") {
                    model.read(agent, on: machine) { text in
                        reading = ("\(agent.name) on \(machine)", text, machine, agent)
                    }
                }
                .controlSize(.small)
                Button("Message") {
                    messaging = messaging == key ? nil : key
                    message = ""
                }
                .controlSize(.small)
            }
            if messaging == key {
                HStack(spacing: 6) {
                    TextField("Message for \(agent.name)", text: $message)
                        .textFieldStyle(.roundedBorder)
                        .onSubmit { sendMessage(agent, machine) }
                    Button("Send") { sendMessage(agent, machine) }
                        .controlSize(.small)
                        .disabled(message.trimmingCharacters(in: .whitespaces).isEmpty)
                }
            }
        }
        .padding(.leading, 14)
    }

    private func sendMessage(_ agent: PeerProtocol.Agent, _ machine: String) {
        let text = message.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return }
        model.send(text, to: agent, on: machine)
        message = ""
        messaging = nil
    }

    private func taskForm(_ machine: String) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("New task on \(machine)").font(Theme.captionFont.weight(.medium)).foregroundStyle(Theme.textSecondary)
            Picker("Agent", selection: $taskAgent) {
                Text("Claude Code").tag("claude")
                Text("Codex").tag("codex")
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            TextField("Folder there, e.g. ~/code/app", text: $taskFolder).textFieldStyle(.roundedBorder)
            TextField("What should it do?", text: $taskText, axis: .vertical)
                .lineLimit(3...6)
                .textFieldStyle(.roundedBorder)
            HStack {
                Text("It runs in a tab there; the answer comes back here.").font(Theme.captionFont).foregroundStyle(Theme.textTertiary)
                Spacer()
                Button("Cancel") { tasking = nil }.controlSize(.small)
                Button("Start") {
                    model.delegate(taskText, agent: taskAgent, folder: taskFolder, on: machine)
                    tasking = nil
                }
                .controlSize(.small)
                .keyboardShortcut(.defaultAction)
                .disabled(taskText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                          || taskFolder.trimmingCharacters(in: .whitespaces).isEmpty)
            }
        }
        .padding(8)
        .background(Theme.chrome)
        .clipShape(RoundedRectangle(cornerRadius: 6))
    }

    // MARK: Tasks given from here

    private var tasks: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text("TASKS").font(Theme.headerFont).foregroundStyle(Theme.textTertiary)
                Spacer()
                if model.tasks.contains(where: { $0.status != "working" }) {
                    Button("Clear Finished") { model.clearFinished() }.buttonStyle(.link).font(Theme.captionFont)
                }
            }
            ForEach(model.tasks) { task in
                VStack(alignment: .leading, spacing: 3) {
                    HStack(spacing: 6) {
                        if task.status == "working" { ProgressView().controlSize(.mini) }
                        Text(task.summary).font(Theme.uiFont).foregroundStyle(Theme.textPrimary).lineLimit(1)
                        Spacer(minLength: 4)
                        Text("\(task.machine) · \(task.status)").font(Theme.captionFont).foregroundStyle(Theme.textTertiary)
                    }
                    if let result = task.result, !result.isEmpty {
                        Text(result).font(Theme.monoFont).foregroundStyle(Theme.textSecondary)
                            .lineLimit(6).textSelection(.enabled)
                    }
                }
                .padding(8)
                .background(Theme.card)
                .clipShape(RoundedRectangle(cornerRadius: 6))
            }
        }
    }

    // MARK: Pairing

    private var pairing: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("PAIR A MAC").font(Theme.headerFont).foregroundStyle(Theme.textTertiary)
            ForEach(center.nearby) { found in
                HStack {
                    Text(found.name).font(Theme.uiFont).foregroundStyle(Theme.textPrimary)
                    Text("nearby").font(Theme.captionFont).foregroundStyle(Theme.textTertiary)
                    Spacer()
                    Button("Pair…") { center.pair(with: found.endpoint, name: found.name) }.controlSize(.small)
                }
            }
            HStack(spacing: 6) {
                TextField("Or an address, e.g. studio.local:52100", text: $address)
                    .textFieldStyle(.roundedBorder)
                    .onSubmit(pairAddress)
                Button("Pair", action: pairAddress).controlSize(.small)
                    .disabled(address.trimmingCharacters(in: .whitespaces).isEmpty)
            }
            if let status = center.pairingStatus { note(status) }
        }
    }

    private func pairAddress() {
        let value = address.trimmingCharacters(in: .whitespaces)
        guard !value.isEmpty else { return }
        center.pair(address: value)
        address = ""
    }

    // MARK: Reading an agent

    private func output(_ shown: (title: String, text: String, machine: String, agent: PeerProtocol.Agent)) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Button { reading = nil } label: { Label("Back", systemImage: "chevron.left") }.buttonStyle(.link)
                Text(shown.title).font(Theme.uiFontMedium).foregroundStyle(Theme.textPrimary).lineLimit(1)
                Spacer()
                Button("Refresh") {
                    model.read(shown.agent, on: shown.machine) { text in reading = (shown.title, text, shown.machine, shown.agent) }
                }
                .controlSize(.small)
            }
            ScrollView {
                Text(shown.text)
                    .font(Theme.monoFont)
                    .foregroundStyle(Theme.textSecondary)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .textSelection(.enabled)
            }
            .frame(maxHeight: .infinity)
            .padding(8)
            .background(Theme.terminalBackground)
            .clipShape(RoundedRectangle(cornerRadius: 6))
        }
    }

    private func note(_ text: String) -> some View {
        Text(text).font(Theme.captionFont).foregroundStyle(Theme.textTertiary).fixedSize(horizontal: false, vertical: true)
    }
}
