import Combine
import SwiftUI

/// Monitors and shells that are descendants of the Claude instance in front.
/// The process-tree boundary is important: a workspace can contain many agents
/// and terminals, but this panel describes only the Claude session being viewed.
struct RuntimePanel: View {
    @EnvironmentObject private var window: WindowContext
    @ObservedObject var store: SessionStore
    @ObservedObject private var center = AgentCenter.shared
    @ObservedObject private var motion = MotionPreferences.shared
    private let refresh = Timer.publish(every: 2, on: .main, in: .common).autoconnect()

    private var workspaceId: String? { window.focusedWorkspace?.workspaceId }
    private var activeClaude: AgentSession? {
        guard let session = center.active(in: workspaceId), session.engine == .claude else { return nil }
        return session
    }
    private var targetPanes: [EnginePane] {
        guard activeClaude == nil, let tabId = window.displayedFocusedTabId else { return [] }
        let snapshot = store.snapshot
        return snapshot.panes.filter { pane in
            guard pane.tabId == tabId,
                  let agent = snapshot.agents.first(where: { $0.paneId == pane.paneId }) else { return false }
            return AgentBrand.forAgent(agent.agent)?.id == AgentSession.Engine.claude.agent
        }
    }

    var body: some View {
        VStack(spacing: 0) {
            header
            Rectangle().fill(Theme.divider).frame(height: 1)
            if entries.isEmpty {
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
            OctetIcon("point.3.connected.trianglepath.dotted", size: 15).foregroundStyle(Theme.textSecondary)
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
            OctetIcon("point.3.connected.trianglepath.dotted", size: 28).foregroundStyle(Theme.textTertiary)
            Text("No active runtimes")
                .font(.system(size: 15, weight: .semibold))
                .foregroundStyle(Theme.textPrimary)
            Text("Monitors and shells started by this Claude instance appear here.")
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
        let snapshot = store.snapshot
        var result: [RuntimeEntry] = []

        for pane in targetPanes {
            guard let info = store.paneProcesses[pane.paneId] else { continue }
            let tab = snapshot.tabs.first { $0.tabId == pane.tabId }
            let location = tab.map { TabAutoName.display(label: $0.label, number: $0.number) } ?? "Terminal"
            for process in info.background where Self.isShell(process.name) {
                let title = Self.commandName(process.name)
                result.append(RuntimeEntry(id: "\(pane.paneId)-\(process.pid)", kind: .shell,
                                           title: title, detail: "PID \(process.pid)",
                                           location: location, paneId: pane.paneId))
            }
        }

        if let session = activeClaude {
            result += activeMonitors(in: session)
            for process in store.nativeRuntimeProcesses[session.id] ?? [] where Self.isShell(process.name) {
                let title = Self.commandName(process.name)
                result.append(RuntimeEntry(id: "\(session.id)-\(process.pid)", kind: .shell,
                                           title: title, detail: "PID \(process.pid)",
                                           location: session.title, paneId: nil, sessionId: session.id))
            }
        }
        return result
    }

    private func reload() {
        var roots: [String: Int] = [:]
        if let session = activeClaude, let pid = session.runtimePID { roots[session.id] = pid }
        store.refreshPaneProcesses(in: workspaceId, nativeRoots: roots)
    }

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

    private func activeMonitors(in session: AgentSession) -> [RuntimeEntry] {
        let now = Date()
        return session.conversation.items.compactMap { item in
            guard case .tool(let call) = item.kind, call.name.caseInsensitiveCompare("Monitor") == .orderedSame,
                  call.result?.localizedCaseInsensitiveContains("monitor started") == true,
                  let input = call.inputObject else { return nil }
            let timeout = (input["timeout_ms"] as? NSNumber)?.doubleValue ?? 120_000
            let expires = item.createdAt.addingTimeInterval(timeout / 1_000)
            guard expires > now else { return nil }
            let title = input["description"] as? String ?? call.summary
            return RuntimeEntry(id: "monitor-\(item.id)", kind: .monitor,
                                title: title.isEmpty ? "Monitor" : title,
                                detail: Self.remaining(until: expires, now: now),
                                location: session.title, paneId: nil, sessionId: session.id)
        }
    }

    private static func isShell(_ raw: String) -> Bool {
        let command = commandName(raw).lowercased()
        return ShellPrompt.shells.contains(command) || ShellPrompt.shells.contains("-" + command)
    }

    private static func remaining(until end: Date, now: Date) -> String {
        let seconds = max(0, Int(end.timeIntervalSince(now)))
        let minutes = seconds / 60
        let remainder = seconds % 60
        return minutes > 0 ? "\(minutes)m \(remainder)s" : "\(remainder)s"
    }
}

private enum RuntimeKind: String, CaseIterable, Identifiable {
    case monitor, shell
    var id: String { rawValue }
    var title: String {
        switch self {
        case .monitor: "Monitors"
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
                OctetIcon(entry.kind == .monitor ? "clock" : "terminal", size: 14)
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
