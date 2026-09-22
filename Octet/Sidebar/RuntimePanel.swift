import Combine
import SwiftUI

/// A live inventory of what the focused workspace is keeping alive. Unlike
/// the project sidebar, this opens from the right so it can stay visible while
/// the person moves between the terminals it describes.
struct RuntimePanel: View {
    @EnvironmentObject private var window: WindowContext
    @ObservedObject var store: SessionStore
    @ObservedObject private var center = AgentCenter.shared
    @ObservedObject private var motion = MotionPreferences.shared
    private let refresh = Timer.publish(every: 2, on: .main, in: .common).autoconnect()

    private var workspaceId: String? { window.focusedWorkspace?.workspaceId }
    private var workspacePanes: [EnginePane] {
        guard let workspaceId else { return [] }
        return store.snapshot.panes.filter { $0.workspaceId == workspaceId }
    }

    var body: some View {
        VStack(spacing: 0) {
            header
            Rectangle().fill(Theme.divider).frame(height: 1)
            if entries.isEmpty && !workspacePanes.isEmpty {
                VStack(spacing: 9) {
                    LoadingLine(width: 34)
                    Text("Inspecting runtimes")
                        .font(Theme.captionFont)
                        .foregroundStyle(Theme.textTertiary)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if entries.isEmpty {
                empty
            } else {
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 14) {
                        ForEach(RuntimeKind.allCases) { kind in
                            let rows = entries.filter { $0.kind == kind }
                            if !rows.isEmpty { section(kind, rows: rows) }
                        }
                    }
                    .padding(10)
                }
            }
        }
        .background(Theme.sidebar)
        .onAppear { reload() }
        .onChange(of: workspaceId) { _, _ in reload() }
        .onReceive(refresh) { _ in reload() }
    }

    private var header: some View {
        HStack(spacing: 7) {
            OctetIcon("terminal", size: 15).foregroundStyle(Theme.textSecondary)
            Text("Runtime").font(Theme.uiFontMedium).foregroundStyle(Theme.textPrimary)
            Text("\(entries.count)")
                .font(Theme.captionFont.monospacedDigit())
                .foregroundStyle(Theme.textTertiary)
            Spacer()
            Button { window.ui.runtimePanelVisible = false } label: {
                OctetIcon("xmark", size: 13)
                    .foregroundStyle(Theme.textSecondary)
                    .frame(width: 24, height: 24)
            }
            .buttonStyle(.plain)
            .help("Close runtime panel")
        }
        .padding(.horizontal, 10)
        .frame(height: Theme.tabBarHeight)
    }

    private var empty: some View {
        VStack(spacing: 8) {
            OctetIcon("terminal", size: 28).foregroundStyle(Theme.textTertiary)
            Text("Nothing running here")
                .font(.system(size: 15, weight: .semibold))
                .foregroundStyle(Theme.textPrimary)
            Text("Shells, monitors, agents, and other processes appear here.")
                .font(Theme.captionFont)
                .foregroundStyle(Theme.textTertiary)
                .multilineTextAlignment(.center)
        }
        .padding(24)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private func section(_ kind: RuntimeKind, rows: [RuntimeEntry]) -> some View {
        VStack(alignment: .leading, spacing: 5) {
            HStack {
                Text(kind.title.uppercased())
                    .font(Theme.headerFont)
                    .kerning(0.4)
                    .foregroundStyle(Theme.textTertiary)
                Spacer()
                Text("\(rows.count)").font(Theme.captionFont).foregroundStyle(Theme.textMuted)
            }
            ForEach(rows) { row in
                RuntimeRow(entry: row) { focus(row) }
            }
        }
    }

    private var entries: [RuntimeEntry] {
        guard let workspaceId else { return [] }
        let snapshot = store.snapshot
        let panes = snapshot.panes.filter { $0.workspaceId == workspaceId }
        var result: [RuntimeEntry] = []

        for pane in panes {
            guard let info = store.paneProcesses[pane.paneId] else { continue }
            let tab = snapshot.tabs.first { $0.tabId == pane.tabId }
            let location = tab.map { TabAutoName.display(label: $0.label, number: $0.number) } ?? "Terminal"
            let agent = snapshot.agents.first { $0.paneId == pane.paneId }
            let processes = (info.foreground + info.background).filter { process in
                let name = Self.commandName(process.name)
                return !ShellPrompt.shells.contains(name) && !ShellPrompt.shells.contains("-" + name)
            }

            if let agent, let brand = AgentBrand.forAgent(agent.agent) {
                result.append(RuntimeEntry(id: "agent-\(pane.paneId)", kind: .agent,
                                           title: brand.displayName, detail: stateLabel(agent.agentStatus),
                                           location: location, paneId: pane.paneId))
            }

            if processes.isEmpty {
                let shell = info.foreground.first.map { Self.commandName($0.name) } ?? "shell"
                result.append(RuntimeEntry(id: "shell-\(pane.paneId)", kind: .shell,
                                           title: shell, detail: "Ready", location: location,
                                           paneId: pane.paneId))
            } else {
                for process in processes where agent == nil || AgentBrand.forAgent(process.name)?.id != AgentBrand.forAgent(agent?.agent)?.id {
                    let title = Self.commandName(process.name)
                    let kind: RuntimeKind = Self.looksLikeMonitor(title, pane.terminalTitle) ? .monitor : .process
                    result.append(RuntimeEntry(id: "\(pane.paneId)-\(process.pid)", kind: kind,
                                               title: title, detail: "PID \(process.pid)",
                                               location: location, paneId: pane.paneId))
                }
            }
        }

        for session in center.sessions(in: workspaceId) {
            result.append(RuntimeEntry(id: "native-\(session.id)", kind: .agent,
                                       title: session.engine.displayName,
                                       detail: session.conversation.isRunning ? "Working" : "Ready",
                                       location: session.title, paneId: nil, sessionId: session.id))
        }
        return result
    }

    private func reload() { store.refreshPaneProcesses(in: workspaceId) }

    private func focus(_ entry: RuntimeEntry) {
        if let pane = entry.paneId {
            window.focusAgent(paneId: pane)
            OctetTerminalRuntime.focusTerminal()
        } else if let session = entry.sessionId {
            center.setActive(session, in: workspaceId)
        }
    }

    private static func commandName(_ raw: String) -> String {
        let name = (raw as NSString).lastPathComponent
        return name.hasPrefix("-") ? String(name.dropFirst()) : name
    }

    private static func looksLikeMonitor(_ command: String, _ title: String?) -> Bool {
        let text = ([command, title].compactMap { $0 }.joined(separator: " ")).lowercased()
        return ["monitor", "watch", "tail", "nodemon", "watchexec", "vite", "webpack", "dev server"]
            .contains { text.contains($0) }
    }
}

private enum RuntimeKind: String, CaseIterable, Identifiable {
    case monitor, agent, process, shell
    var id: String { rawValue }
    var title: String {
        switch self {
        case .monitor: "Monitors"
        case .agent: "Agents"
        case .process: "Processes"
        case .shell: "Shells"
        }
    }
}

private struct RuntimeEntry: Identifiable {
    let id: String
    let kind: RuntimeKind
    let title: String
    let detail: String
    let location: String
    let paneId: String?
    var sessionId: String?
}

private struct RuntimeRow: View {
    let entry: RuntimeEntry
    let action: () -> Void
    @State private var hovered = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: 8) {
                OctetIcon(entry.kind == .agent ? "tool.agent" : entry.kind == .monitor ? "clock" : "terminal", size: 14)
                    .foregroundStyle(entry.kind == .monitor ? Theme.accent : Theme.textSecondary)
                    .frame(width: 18)
                VStack(alignment: .leading, spacing: 2) {
                    HStack {
                        Text(entry.title).font(Theme.uiFontMedium).foregroundStyle(Theme.textPrimary).lineLimit(1)
                        Spacer(minLength: 4)
                        Text(entry.detail).font(Theme.captionFont).foregroundStyle(Theme.textTertiary).lineLimit(1)
                    }
                    Text(entry.location)
                        .font(Theme.captionFont)
                        .foregroundStyle(Theme.textTertiary)
                        .lineLimit(1)
                }
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 7)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(hovered ? Theme.hover : Theme.card)
            .overlay(RoundedRectangle(cornerRadius: Theme.rowRadius).strokeBorder(Theme.border, lineWidth: 1))
            .clipShape(RoundedRectangle(cornerRadius: Theme.rowRadius))
        }
        .buttonStyle(.plain)
        .onHover { hovered = $0 }
        .accessibilityLabel("\(entry.title), \(entry.detail), \(entry.location)")
    }
}
