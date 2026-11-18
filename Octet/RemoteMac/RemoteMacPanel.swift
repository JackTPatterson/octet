import AppKit
import SwiftUI

/// The Remote Macs window: the Macs this one is signed in to, their agents
/// live, one agent's conversation to read and answer, and pairing another.
struct RemoteMacPanel: View {
    @ObservedObject private var center = RemoteMacCenter.shared
    @State private var link = ""
    @State private var draft = ""

    var body: some View {
        VStack(spacing: 0) {
            header
            Rectangle().fill(Theme.divider).frame(height: 1)
            if center.selection != nil {
                conversation
            } else {
                list
            }
            if let notice = center.notice {
                Rectangle().fill(Theme.divider).frame(height: 1)
                HStack(alignment: .top, spacing: 8) {
                    Text(notice).font(Theme.interfaceFont(12)).foregroundStyle(Theme.textSecondary)
                        .frame(maxWidth: .infinity, alignment: .leading)
                    OctetButton(title: "Dismiss", kind: .ghost, compact: true) { center.notice = nil }
                }
                .padding(.horizontal, 14).padding(.vertical, 8)
            }
        }
        .frame(minWidth: 420, maxWidth: .infinity, minHeight: 360, maxHeight: .infinity)
        .background(Theme.chrome)
    }

    // MARK: Header

    private var header: some View {
        HStack(spacing: 8) {
            if center.selection != nil {
                OctetButton(title: "Back", icon: "chevron.left", kind: .ghost, compact: true) { center.close() }
            }
            VStack(alignment: .leading, spacing: 1) {
                Text(center.openThread?.title ?? "Remote Macs")
                    .font(Theme.interfaceFont(13, weight: .semibold)).foregroundStyle(Theme.textPrimary).lineLimit(1)
                if let machine = center.openMachine {
                    Text("\(machine.saved.name) · \(statusText(machine))")
                        .font(Theme.interfaceFont(11)).foregroundStyle(Theme.textTertiary).lineLimit(1)
                }
            }
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 14).padding(.top, 28).padding(.bottom, 10)
    }

    private func statusText(_ machine: RemoteMacCenter.Machine) -> String {
        switch machine.state {
        case .connecting: "Connecting…"
        case .online: "Connected"
        case .offline(let reason): "Offline — \(reason)"
        case .revoked: "Removed this Mac. Pair again."
        }
    }

    private func color(_ state: PhoneHostConnectionState) -> Color {
        switch state {
        case .online: .green
        case .connecting: .orange
        default: Theme.textTertiary
        }
    }

    // MARK: Macs

    private var list: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                if center.machines.isEmpty {
                    Text("No Macs yet. On the other Mac open Settings › Phone, turn it on, press Show Code and paste the link or address and code below.")
                        .font(Theme.interfaceFont(12.5)).foregroundStyle(Theme.textSecondary)
                }
                ForEach(center.machines) { machine in card(machine) }
                pair
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(14)
        }
        .octetScrollIndicators()
    }

    private func card(_ machine: RemoteMacCenter.Machine) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                Circle().fill(color(machine.state)).frame(width: 7, height: 7)
                VStack(alignment: .leading, spacing: 1) {
                    Text(machine.saved.name).font(Theme.interfaceFont(13, weight: .semibold)).foregroundStyle(Theme.textPrimary)
                    Text("\(machine.saved.host):\(machine.saved.port) · \(statusText(machine))")
                        .font(Theme.interfaceFont(11)).foregroundStyle(Theme.textTertiary).lineLimit(1)
                }
                Spacer(minLength: 0)
                if case .offline = machine.state {
                    OctetButton(title: "Retry", kind: .secondary, compact: true) { center.reconnect(machine.id) }
                }
                OctetButton(title: "Remove", kind: .destructive, compact: true) { center.forget(machine.id) }
            }
            if machine.online || !machine.threads.isEmpty {
                if machine.threads.isEmpty {
                    Text("No agents running there.").font(Theme.interfaceFont(11.5)).foregroundStyle(Theme.textTertiary)
                }
                ForEach(machine.projects, id: \.id) { project in
                    let threads = machine.threads.filter { $0.projectID == project.id }
                    if !threads.isEmpty {
                        Text(project.title).font(Theme.interfaceFont(11, weight: .medium)).foregroundStyle(Theme.textTertiary)
                            .padding(.top, 4)
                        ForEach(threads, id: \.id) { thread in row(thread, machine: machine) }
                    }
                }
            }
        }
        .padding(12)
        .background(RoundedRectangle(cornerRadius: Theme.controlRadius).strokeBorder(Theme.border, lineWidth: 1))
    }

    private func row(_ thread: PhoneThread, machine: RemoteMacCenter.Machine) -> some View {
        Button { center.open(machine: machine.id, thread: thread.id) } label: {
            HStack(spacing: 8) {
                Circle().fill(dot(thread.status)).frame(width: 6, height: 6)
                Text(thread.title).font(Theme.interfaceFont(12.5)).foregroundStyle(Theme.textPrimary).lineLimit(1)
                Spacer(minLength: 8)
                Text(label(thread)).font(Theme.interfaceFont(11)).foregroundStyle(Theme.textTertiary)
            }
            .padding(.vertical, 4)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    private func dot(_ status: PhoneThreadStatus) -> Color {
        switch status {
        case .running: .blue
        case .waiting: .orange
        case .failed: .red
        case .completed: .green
        case .idle: Theme.textTertiary
        }
    }

    private func label(_ thread: PhoneThread) -> String {
        let status: String = switch thread.status {
        case .running: "Working"
        case .waiting: "Needs you"
        case .failed: "Failed"
        case .completed: "Done"
        case .idle: "Idle"
        }
        return "\(thread.agent) · \(status)"
    }

    private var pair: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Connect a Mac").font(Theme.interfaceFont(12, weight: .semibold)).foregroundStyle(Theme.textSecondary)
            HStack(spacing: 8) {
                OctetTextField(placeholder: "http://studio.local:52200/#token=…  or  studio.local:52200 CODE", text: $link) { submitLink() }
                OctetButton(title: center.pairing ? "Connecting…" : "Connect", kind: .primary, compact: true) { submitLink() }
                    .disabled(center.pairing || link.trimmingCharacters(in: .whitespaces).isEmpty)
            }
            Text("Pair each Mac with the other and both can see the other's agents.")
                .font(Theme.interfaceFont(11)).foregroundStyle(Theme.textTertiary)
        }
    }

    private func submitLink() {
        let text = link
        Task {
            await center.pair(text)
            if center.notice == nil { link = "" }
        }
    }

    // MARK: Conversation

    private var conversation: some View {
        VStack(spacing: 0) {
            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 12) {
                        ForEach(center.items, id: \.id) { item in itemView(item).id(item.id) }
                        if center.items.isEmpty {
                            Text("Loading the conversation…").font(Theme.interfaceFont(12)).foregroundStyle(Theme.textTertiary)
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(14)
                }
                .octetScrollIndicators()
                .onChange(of: center.items.last?.id) { _, id in
                    if let id { withAnimation(.easeOut(duration: 0.15)) { proxy.scrollTo(id, anchor: .bottom) } }
                }
                .onChange(of: center.items.last.map(textLength)) { _, _ in
                    if let id = center.items.last?.id { proxy.scrollTo(id, anchor: .bottom) }
                }
            }
            if let approval = center.approval {
                Rectangle().fill(Theme.divider).frame(height: 1)
                VStack(alignment: .leading, spacing: 8) {
                    Text(approval.prompt).font(Theme.interfaceFont(12)).foregroundStyle(Theme.textPrimary).lineLimit(6)
                    HStack(spacing: 8) {
                        OctetButton(title: "Allow", kind: .primary, compact: true) { center.answer(allow: true) }
                        OctetButton(title: "Deny", kind: .secondary, compact: true) { center.answer(allow: false) }
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(12)
            }
            Rectangle().fill(Theme.divider).frame(height: 1)
            HStack(spacing: 8) {
                OctetTextField(placeholder: "Message this agent", text: $draft) { sendDraft() }
                if center.openThread?.status == .running {
                    OctetButton(title: "Stop", kind: .secondary, compact: true) { center.stopAgent() }
                }
                OctetButton(title: "Send", kind: .primary, compact: true) { sendDraft() }
                    .disabled(draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || center.openMachine?.online != true)
            }
            .padding(12)
        }
    }

    private func textLength(_ item: PhoneItem) -> Int {
        switch item {
        case .user(_, let text, _), .assistant(_, let text, _), .reasoning(_, let text, _): text.count
        case .tool(_, _, _, let output, _, _): output?.count ?? 0
        }
    }

    private func sendDraft() {
        let text = draft.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return }
        center.send(text)
        draft = ""
    }

    @ViewBuilder
    private func itemView(_ item: PhoneItem) -> some View {
        switch item {
        case .user(_, let text, _):
            Text(text).font(Theme.interfaceFont(13)).foregroundStyle(Theme.textPrimary).textSelection(.enabled)
                .padding(.horizontal, 10).padding(.vertical, 7)
                .background(RoundedRectangle(cornerRadius: Theme.controlRadius).fill(Theme.textPrimary.opacity(0.07)))
        case .assistant(_, let text, _):
            Text(text).font(Theme.interfaceFont(13)).foregroundStyle(Theme.textPrimary).textSelection(.enabled)
        case .reasoning(_, let text, _):
            Text(text).font(Theme.interfaceFont(12)).italic().foregroundStyle(Theme.textTertiary).lineLimit(4)
        case .tool(_, let name, let input, let output, let failed, _):
            VStack(alignment: .leading, spacing: 3) {
                Text("\(name)  \(input)").font(.system(size: 11.5, design: .monospaced)).foregroundStyle(Theme.textSecondary).lineLimit(2)
                if let output, !output.isEmpty {
                    Text(String(output.prefix(600))).font(.system(size: 11, design: .monospaced))
                        .foregroundStyle(failed ? Color.red : Theme.textTertiary).lineLimit(6)
                }
            }
        }
    }
}

/// The window the Window menu opens.
@MainActor
enum RemoteMacWindow {
    private static var window: NSWindow?

    static func show() {
        RemoteMacCenter.shared.start()
        if window == nil {
            let created = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 520, height: 640),
                                   styleMask: [.titled, .closable, .resizable, .miniaturizable, .fullSizeContentView],
                                   backing: .buffered, defer: false)
            created.title = "Remote Macs"
            created.titlebarAppearsTransparent = true
            created.titleVisibility = .hidden
            created.isReleasedWhenClosed = false
            let hosting = NSHostingController(rootView: RemoteMacPanel().background(Theme.chrome.ignoresSafeArea()))
            hosting.sizingOptions = []
            created.contentViewController = hosting
            created.setContentSize(NSSize(width: 520, height: 640))
            created.setFrameAutosaveName("OctetRemoteMacsWindow")
            if created.frame.origin == .zero { created.center() }
            window = created
        }
        NSApp.activate(ignoringOtherApps: true)
        window?.makeKeyAndOrderFront(nil)
    }
}

/// Window › Remote Macs.
struct RemoteMacCommands: Commands {
    var body: some Commands {
        CommandGroup(after: .windowArrangement) {
            Button("Remote Macs") { RemoteMacWindow.show() }
        }
    }
}
