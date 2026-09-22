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
    @State private var flashingEntryIDs: Set<String> = []
    private let refresh = Timer.publish(every: 4, on: .main, in: .common).autoconnect()

    private var workspaceId: String? { window.focusedWorkspace?.workspaceId }
    private var activeClaude: AgentSession? {
        guard let session = center.active(in: workspaceId), session.engine == .claude else { return nil }
        return session
    }
    private var targetPanes: [EnginePane] {
        guard activeClaude == nil, let tabId = window.displayedFocusedTabId else { return [] }
        // Agent discovery can lag behind the process itself (and new Claude
        // versions do not always emit the same marker). Inspect every pane in
        // the selected tab, then root its descendants at Claude in reload().
        // The tab boundary still prevents runtimes from another tab leaking in.
        return store.snapshot.panes.filter { $0.tabId == tabId }
    }

    var body: some View {
        runtimeContent
        .background(Theme.sidebar)
        .onAppear {
            window.ui.seenRuntimeEntryIDs.formUnion(entries.map(\.id))
            reload()
        }
        .onChange(of: workspaceId) { _, _ in
            window.ui.seenRuntimeEntryIDs.formUnion(entries.map(\.id))
            flashingEntryIDs = []
            window.ui.runtimeInspectorEntryID = nil
            reload()
        }
        .onChange(of: entries.map(\.id)) { _, ids in
            revealNewEntries(ids)
            if let selected = window.ui.runtimeInspectorEntryID, !ids.contains(selected) {
                window.ui.runtimeInspectorEntryID = nil
            }
        }
        .onReceive(refresh) { _ in reload() }
    }

    @ViewBuilder private var runtimeContent: some View {
        let current = entries
        if let selectedID = window.ui.runtimeInspectorEntryID,
           let selected = current.first(where: { $0.id == selectedID }) {
            HStack(spacing: 0) {
                RuntimeInspector(entry: selected) { focus(selected) }
                    .frame(width: 387)
                Rectangle().fill(Theme.divider).frame(width: 1)
                RuntimeRail(entries: current, selectedID: selectedID,
                            select: select, showList: showList,
                            close: close)
                    .frame(width: 52)
            }
        } else {
            VStack(spacing: 0) {
                header
                Rectangle().fill(Theme.divider).frame(height: 1)
                if current.isEmpty {
                    empty
                } else {
                    ScrollView {
                        LazyVStack(alignment: .leading, spacing: 14) {
                            ForEach(RuntimeKind.allCases) { kind in
                                let rows = current.filter { $0.kind == kind }
                                if !rows.isEmpty { section(kind, rows: rows) }
                            }
                        }
                        .padding(10)
                    }
                    .scrollIndicators(.hidden)
                }
            }
        }
    }

    private func close() {
        withoutLayoutAnimation {
            window.ui.runtimeInspectorEntryID = nil
            window.ui.runtimePanelVisible = false
        }
    }

    private func showList() {
        withoutLayoutAnimation { window.ui.runtimeInspectorEntryID = nil }
    }

    private func select(_ entry: RuntimeEntry) {
        withoutLayoutAnimation { window.ui.runtimeInspectorEntryID = entry.id }
        focus(entry)
    }

    private func withoutLayoutAnimation(_ changes: () -> Void) {
        var transaction = Transaction()
        transaction.disablesAnimations = true
        withTransaction(transaction, changes)
    }

    private var header: some View {
        HStack(spacing: 7) {
            OctetIcon("point.3.connected.trianglepath.dotted", size: 15).foregroundStyle(Theme.textSecondary)
            Text("Runtime").font(Theme.uiFontMedium).foregroundStyle(Theme.textPrimary)
            Text("\(entries.count)")
                .font(Theme.captionFont.monospacedDigit())
                .foregroundStyle(Theme.textTertiary)
            Spacer()
            Button { close() } label: {
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
                RuntimeRow(entry: row, flashes: flashingEntryIDs.contains(row.id)) { select(row) }
            }
        }
    }

    private func revealNewEntries(_ ids: [String]) {
        let current = Set(ids)
        let added = current.subtracting(window.ui.seenRuntimeEntryIDs)
        window.ui.seenRuntimeEntryIDs.formUnion(current)
        flashingEntryIDs.formIntersection(current)
        guard !added.isEmpty else { return }
        window.ui.runtimePanelVisible = true
        flashingEntryIDs.formUnion(added)
        DispatchQueue.main.asyncAfter(deadline: .now() + (motion.animates(.sidebar) ? 0.85 : 0.15)) {
            flashingEntryIDs.subtract(added)
        }
    }

    private var entries: [RuntimeEntry] {
        let snapshot = store.snapshot
        var result: [RuntimeEntry] = []

        for pane in targetPanes {
            guard let info = store.paneProcesses[pane.paneId] else { continue }
            let tab = snapshot.tabs.first { $0.tabId == pane.tabId }
            let location = tab.map { TabAutoName.display(label: $0.label, number: $0.number) } ?? "Terminal"
            var shownShells = Set<String>()
            for process in info.background where Self.isShell(process.name) {
                let title = Self.commandName(process.name)
                guard shownShells.insert(title.lowercased()).inserted else { continue }
                result.append(RuntimeEntry(id: "\(pane.paneId)-\(process.pid)", kind: .shell,
                                           title: title, detail: "Active",
                                           location: location, command: process.name,
                                           prompt: nil, output: nil, process: title,
                                           depth: 0, accentSeed: 0, agentID: nil, modelName: nil,
                                           paneId: pane.paneId))
            }
            let spawned = store.spawnedRuntimeAgents.filter { $0.paneId == pane.paneId }
            result += processAgents(spawned, location: location, sessionId: nil)
        }

        if let session = activeClaude {
            result += activeMonitors(in: session)
            result += activeSubagents(in: session)
            var shownShells = Set<String>()
            for process in store.nativeRuntimeProcesses[session.id] ?? [] where Self.isShell(process.name) {
                let title = Self.commandName(process.name)
                guard shownShells.insert(title.lowercased()).inserted else { continue }
                result.append(RuntimeEntry(id: "\(session.id)-\(process.pid)", kind: .shell,
                                           title: title, detail: "Active",
                                           location: session.title, command: process.name,
                                           prompt: nil, output: nil, process: title,
                                           depth: 0, accentSeed: 0, agentID: nil, modelName: nil,
                                           paneId: nil, sessionId: session.id))
            }
            let processes = store.nativeRuntimeProcesses[session.id] ?? []
            let spawned = processes.compactMap { process -> SpawnedRuntimeAgent? in
                guard let agent = Self.agentExecutable(process.name) else { return nil }
                return SpawnedRuntimeAgent(pid: process.pid, parentPid: process.parentPid, agent: agent,
                                           name: AgentBrand.forAgent(agent)?.displayName ?? agent,
                                           paneId: nil, tabId: nil, workspaceId: session.workspaceId, cwd: session.cwd)
            }
            result += processAgents(spawned, location: session.title, sessionId: session.id)
        }
        return result
    }

    private func reload() {
        var roots: [String: Int] = [:]
        for session in center.sessions where session.conversation.isRunning {
            if let pid = session.runtimePID { roots[session.id] = pid }
        }
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

    private static func agentExecutable(_ raw: String) -> String? {
        AgentBrand.runtimeAgentID(forExecutable: raw)
    }

    private func processAgents(_ agents: [SpawnedRuntimeAgent], location: String,
                               sessionId: String?) -> [RuntimeEntry] {
        let ids = Set(agents.map(\.pid))
        let byId = Dictionary(uniqueKeysWithValues: agents.map { ($0.pid, $0) })
        return agents.map { agent in
            var depth = 0
            var parent = agent.parentPid
            var visited = Set<Int>()
            while ids.contains(parent), let ancestor = byId[parent], visited.insert(parent).inserted {
                depth += 1
                parent = ancestor.parentPid
            }
            return RuntimeEntry(id: "process-agent-\(agent.pid)", kind: .agent,
                                title: agent.name, detail: "Model",
                                location: location, command: agent.agent,
                                prompt: "Started by another agent", output: nil,
                                process: Self.commandName(agent.agent), depth: depth,
                                accentSeed: Self.seed(agent.agent), agentID: agent.agent, modelName: nil,
                                paneId: agent.paneId,
                                sessionId: sessionId)
        }
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
                                location: session.title, command: input["command"] as? String,
                                prompt: input["description"] as? String, output: call.result,
                                process: "Watching", depth: 0, accentSeed: 0,
                                agentID: nil, modelName: nil,
                                paneId: nil, sessionId: session.id)
        }
    }

    private func activeSubagents(in session: AgentSession) -> [RuntimeEntry] {
        guard session.conversation.isRunning else { return [] }
        let now = Date()
        let calls: [(item: AgentItem, call: AgentToolCall)] = session.conversation.items.compactMap { item in
            guard case .tool(let call) = item.kind,
                  call.name.caseInsensitiveCompare("Agent") == .orderedSame
                    || call.name.caseInsensitiveCompare("Task") == .orderedSame else { return nil }
            return (item, call)
        }
        let byId = Dictionary(uniqueKeysWithValues: calls.map { ($0.item.id, $0) })
        let childrenByParent = Dictionary(grouping: session.conversation.items.compactMap { item in
            item.parent.map { ($0, item) }
        }, by: \.0).mapValues { $0.map(\.1) }
        var visible = Set(calls.filter { $0.call.result == nil }.map { $0.item.id })
        // Keep the ownership chain visible even if an agent's launch call has
        // already returned while one of its descendants is still working.
        var frontier = Array(visible)
        while let id = frontier.popLast(), let parent = byId[id]?.item.parent,
              byId[parent] != nil, visible.insert(parent).inserted {
            frontier.append(parent)
        }

        return calls.compactMap { pair in
            let item = pair.item
            let call = pair.call
            guard visible.contains(item.id), let input = call.inputObject else { return nil }
            let title = input["name"] as? String
                ?? input["description"] as? String
                ?? call.summary
            let prompt = input["prompt"] as? String
            let children = childrenByParent[item.id] ?? []
            let process = children.reversed().compactMap { child -> String? in
                guard case .tool(let childCall) = child.kind, childCall.result == nil else { return nil }
                if childCall.name.caseInsensitiveCompare("Agent") == .orderedSame
                    || childCall.name.caseInsensitiveCompare("Task") == .orderedSame {
                    return "Managing subagent"
                }
                return childCall.summary.isEmpty ? childCall.displayName : "\(childCall.displayName)  \(childCall.summary)"
            }.first ?? (call.result == nil ? "Working" : "Finished")
            let output = children.reversed().compactMap { child -> String? in
                switch child.kind {
                case .text(let text) where !text.isEmpty: return text
                case .tool(let childCall) where childCall.result?.isEmpty == false: return childCall.result
                case .notice(let text) where !text.isEmpty: return text
                default: return nil
                }
            }.first ?? call.result
            let elapsed = max(0, Int(now.timeIntervalSince(item.createdAt)))
            var depth = 0
            var parent = item.parent
            var visited = Set<String>()
            while let id = parent, let ancestor = byId[id], visited.insert(id).inserted {
                depth += 1
                parent = ancestor.item.parent
            }
            return RuntimeEntry(id: "agent-\(item.id)", kind: .agent,
                                title: title.isEmpty ? "Subagent" : title,
                                detail: call.result == nil ? "\(elapsed)s" : "Parent",
                                location: session.title, command: prompt,
                                prompt: prompt, output: output, process: process,
                                depth: depth, accentSeed: Self.seed(item.id),
                                agentID: session.engine.agent, modelName: modelName(for: session),
                                paneId: nil, sessionId: session.id)
        }
    }

    private func modelName(for session: AgentSession) -> String {
        switch session.engine {
        case .claude:
            return AgentSession.model(session.model)?.title ?? friendlyModelName(session.model)
        case .codex:
            return CodexCatalogStore.shared.model(session.model)?.displayName ?? friendlyModelName(session.model)
        case .pi:
            return session.piModels.first(where: { $0.id == session.model || $0.modelId == session.model })?.name
                ?? friendlyModelName(session.model)
        case .opencode:
            return session.openCodeModel?.name ?? friendlyModelName(session.model)
        case .qwen:
            return friendlyModelName(session.model)
        }
    }

    private func friendlyModelName(_ raw: String) -> String {
        TwinStyle.shortModel(raw).replacingOccurrences(of: "-", with: " ")
    }

    private static func seed(_ value: String) -> Int {
        value.unicodeScalars.reduce(0) { ($0 &* 31 &+ Int($1.value)) % 5 }
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
    case monitor, agent, shell
    var id: String { rawValue }
    var title: String {
        switch self {
        case .monitor: "Monitors"
        case .agent: "Agents"
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
    let command: String?
    let prompt: String?
    let output: String?
    let process: String?
    let depth: Int
    let accentSeed: Int
    let agentID: String?
    let modelName: String?
    let paneId: String?
    var sessionId: String?

    var tint: Color {
        guard kind == .agent else { return kind == .monitor ? Theme.accent : Theme.textSecondary }
        let colors = [Theme.palette.syntaxBuiltin, Theme.palette.syntaxFlag, Theme.palette.syntaxString,
                      Theme.palette.syntaxPath, Theme.palette.syntaxVariable]
        return Color(hex: colors[accentSeed % colors.count])
    }
}

private struct RuntimeRow: View {
    let entry: RuntimeEntry
    let flashes: Bool
    let action: () -> Void
    @ObservedObject private var motion = MotionPreferences.shared
    @State private var hovered = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: 0) {
                if entry.depth > 0 {
                    Color.clear.frame(width: CGFloat(entry.depth - 1) * 12)
                    Image(systemName: "arrow.turn.down.right")
                        .font(.system(size: 11, weight: .medium))
                        .foregroundStyle(entry.tint.opacity(0.72))
                        .frame(width: 22)
                        .accessibilityHidden(true)
                }
                HStack(alignment: .top, spacing: 8) {
                RuntimeGlyph(entry: entry, size: 14).frame(width: 18)
                VStack(alignment: .leading, spacing: 2) {
                    HStack {
                        Text(entry.title).font(Theme.uiFontMedium).foregroundStyle(Theme.textPrimary).lineLimit(1)
                        if let modelName = entry.modelName, !modelName.isEmpty {
                            Text(modelName)
                                .font(Theme.captionFont)
                                .foregroundStyle(entry.tint)
                                .lineLimit(1)
                        }
                        Spacer(minLength: 4)
                        Text(entry.detail).font(Theme.captionFont).foregroundStyle(Theme.textTertiary).lineLimit(1)
                    }
                    Text(entry.location)
                        .font(Theme.captionFont)
                        .foregroundStyle(Theme.textTertiary)
                        .lineLimit(1)
                }
                OctetIcon("chevron.right", size: 11)
                    .foregroundStyle(Theme.textTertiary)
                    .padding(.top, 2)
                }
                .padding(.horizontal, 8)
                .padding(.vertical, 7)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(flashes ? entry.tint.opacity(0.22) : hovered ? Theme.hover : Theme.card)
                .overlay(RoundedRectangle(cornerRadius: Theme.rowRadius).strokeBorder(Theme.border, lineWidth: 1))
                .clipShape(RoundedRectangle(cornerRadius: Theme.rowRadius))
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .buttonStyle(.plain)
        .onHover { hovered = $0 }
        .animation(motion.animation(.sidebar, .easeOut(duration: 0.55)), value: flashes)
        .accessibilityLabel("\(entry.title), level \(entry.depth + 1), \(entry.detail), \(entry.location)")
    }
}

private struct RuntimeGlyph: View {
    let entry: RuntimeEntry
    let size: CGFloat

    var body: some View {
        Group {
            if entry.kind == .monitor {
                Image(systemName: "eye")
                    .font(.system(size: size, weight: .medium))
                    .foregroundStyle(entry.tint)
            } else if entry.kind == .agent, let brand = AgentBrand.forAgent(entry.agentID) {
                AgentLogo(brand: brand, size: size)
            } else if entry.kind == .agent {
                OctetIcon("tool.agent", size: size).foregroundStyle(entry.tint)
            } else {
                OctetIcon("terminal", size: size).foregroundStyle(entry.tint)
            }
        }
        .accessibilityHidden(true)
    }
}

private struct RuntimeRail: View {
    let entries: [RuntimeEntry]
    let selectedID: String
    let select: (RuntimeEntry) -> Void
    let showList: () -> Void
    let close: () -> Void

    var body: some View {
        VStack(spacing: 0) {
            Button(action: showList) {
                OctetIcon("chevron.left", size: 13)
                    .foregroundStyle(Theme.textSecondary)
                    .frame(width: 32, height: 30)
            }
            .buttonStyle(.plain)
            .help("Show runtime list")
            Rectangle().fill(Theme.divider).frame(height: 1)
            ScrollView {
                LazyVStack(spacing: 7) {
                    ForEach(entries) { entry in
                        Button { select(entry) } label: {
                            ZStack {
                                RoundedRectangle(cornerRadius: 7)
                                    .fill(entry.tint.opacity(entry.id == selectedID ? 0.14 : 0.055))
                                RoundedRectangle(cornerRadius: 7)
                                    .strokeBorder(entry.tint.opacity(entry.id == selectedID ? 0.5 : 0.18),
                                                  lineWidth: 1)
                                RuntimeGlyph(entry: entry, size: 16)
                            }
                            .frame(width: 34, height: 34)
                        }
                        .buttonStyle(.plain)
                        .help(entry.title)
                        .accessibilityLabel(entry.title)
                        .accessibilityValue(entry.id == selectedID ? "Selected" : "")
                    }
                }
                .padding(.vertical, 8)
            }
            .scrollIndicators(.hidden)
            Spacer(minLength: 0)
            Rectangle().fill(Theme.divider).frame(height: 1)
            Button(action: close) {
                OctetIcon("xmark", size: 12)
                    .foregroundStyle(Theme.textSecondary)
                    .frame(width: 32, height: 30)
            }
            .buttonStyle(.plain)
            .help("Close runtime panel")
        }
        .background(Theme.chrome)
    }
}

private struct RuntimeInspector: View {
    let entry: RuntimeEntry
    let focus: () -> Void

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 9) {
                RuntimeGlyph(entry: entry, size: 18).frame(width: 22)
                VStack(alignment: .leading, spacing: 1) {
                    Text(entry.title)
                        .font(Theme.uiFontMedium)
                        .foregroundStyle(Theme.textPrimary)
                        .lineLimit(1)
                    HStack(spacing: 5) {
                        if let model = entry.modelName, !model.isEmpty {
                            Text(model).foregroundStyle(entry.tint)
                        }
                        Text(entry.detail).foregroundStyle(Theme.textTertiary)
                    }
                    .font(Theme.captionFont.monospacedDigit())
                }
                Spacer(minLength: 8)
                Button(action: focus) {
                    OctetIcon("arrow.right", size: 12)
                        .foregroundStyle(Theme.textSecondary)
                        .frame(width: 26, height: 26)
                }
                .buttonStyle(.plain)
                .help("Focus source")
            }
            .padding(.horizontal, 12)
            .frame(height: Theme.tabBarHeight + 8)
            .overlay(alignment: .top) { Rectangle().fill(entry.tint).frame(height: 2) }
            Rectangle().fill(Theme.divider).frame(height: 1)
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    RuntimeInspectorSection(title: "Status", tint: entry.tint) {
                        HStack(spacing: 7) {
                            LoadingLine(width: 16, color: entry.tint)
                            Text(entry.process ?? (entry.kind == .monitor ? "Watching" : "Active"))
                                .font(Theme.uiFontMedium)
                                .foregroundStyle(Theme.textPrimary)
                        }
                    }
                    if let prompt = entry.prompt ?? entry.command, !prompt.isEmpty {
                        RuntimeInspectorSection(title: entry.kind == .agent ? "Assigned prompt" : "Command",
                                                tint: entry.tint) {
                            Text(prompt)
                                .font(entry.kind == .agent ? Theme.uiFont : Theme.monoFont)
                                .foregroundStyle(Theme.textSecondary)
                                .textSelection(.enabled)
                        }
                    }
                    if let output = entry.output, !output.isEmpty {
                        RuntimeInspectorSection(title: "Latest output", tint: entry.tint) {
                            Text(output)
                                .font(Theme.uiFont)
                                .foregroundStyle(Theme.textSecondary)
                                .textSelection(.enabled)
                        }
                    }
                    RuntimeInspectorSection(title: "Context", tint: entry.tint) {
                        VStack(alignment: .leading, spacing: 6) {
                            inspectorMetadata("Session", entry.location)
                            inspectorMetadata("Runtime", String(entry.kind.title.dropLast()))
                            if entry.kind == .agent { inspectorMetadata("Hierarchy", "Level \(entry.depth + 1)") }
                        }
                    }
                }
                .padding(14)
            }
            .scrollIndicators(.hidden)
        }
        .background(Theme.sidebar)
    }

    private func inspectorMetadata(_ label: String, _ value: String) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Text(label).foregroundStyle(Theme.textTertiary).frame(width: 68, alignment: .leading)
            Text(value).foregroundStyle(Theme.textPrimary).textSelection(.enabled)
        }
        .font(Theme.captionFont)
    }
}

private struct RuntimeInspectorSection<Content: View>: View {
    let title: String
    let tint: Color
    let content: Content

    init(title: String, tint: Color, @ViewBuilder content: () -> Content) {
        self.title = title
        self.tint = tint
        self.content = content()
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 7) {
            Text(title.uppercased())
                .font(Theme.headerFont)
                .kerning(0.35)
                .foregroundStyle(tint)
            content
                .frame(maxWidth: .infinity, alignment: .leading)
        }
    }
}

private struct RuntimeDetail: View {
    let label: String
    let text: String
    let tint: Color
    let monospaced: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(label.uppercased())
                .font(Theme.headerFont)
                .foregroundStyle(tint)
            Text(text)
                .font(monospaced ? Theme.monoFont : Theme.captionFont)
                .foregroundStyle(Theme.textSecondary)
                .lineLimit(6)
                .fixedSize(horizontal: false, vertical: true)
                .textSelection(.enabled)
        }
        .padding(.top, 4)
    }
}
