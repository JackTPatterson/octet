import AppKit
import SwiftUI

/// Browse and install MCP servers, plugins, skills and prompts for every
/// agent from one window, then reload running agents in place.
struct MarketplaceView: View {
    @ObservedObject var store: MarketplaceStore
    @State private var editing: LibraryDraft?
    @State private var addingServer = false

    var body: some View {
        HStack(spacing: 0) {
            sidebar
            Rectangle().fill(Theme.divider).frame(width: 1)
            VStack(spacing: 0) {
                header
                Rectangle().fill(Theme.divider).frame(height: 1)
                content
            }
        }
        .frame(minWidth: 820, minHeight: 540)
        .overlay(alignment: .bottomTrailing) { ToastStack(center: ToastCenter.shared) }
        .overlay { ConfirmDialog(center: ConfirmCenter.shared) }
        .background(Theme.chrome)
        .background(DarkTransparentTitleBar())
        .background(ThemedWindow(themeName: SettingsStore.shared.themeKey))
        .preferredColorScheme(Theme.colorScheme)
        .onAppear {
            store.refreshAll()
            #if DEBUG
            if let name = ProcessInfo.processInfo.environment["HERD_MARKETPLACE_SECTION"],
               let section = MarketplaceStore.Section(rawValue: name) {
                store.section = section
            }
            #endif
        }
        .sheet(item: $editing) { draft in
            LibraryEditor(store: store, draft: draft) { editing = nil }
        }
        .sheet(isPresented: $addingServer) {
            ServerEditor(store: store) { addingServer = false }
        }
    }

    private var sidebar: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text("MARKETPLACE")
                .font(Theme.headerFont)
                .foregroundStyle(Theme.textTertiary)
                .padding(.horizontal, 12)
                .padding(.top, 30)
                .padding(.bottom, 6)
            ForEach(MarketplaceStore.Section.allCases) { section in
                SidebarRow(
                    title: section.title,
                    symbol: section.symbol,
                    count: countLabel(of: section),
                    selected: store.section == section,
                    loading: store.loading.contains(section)
                ) { store.section = section }
            }
            Spacer()
            if !store.hosts.isEmpty {
                Text("AGENTS")
                    .font(Theme.headerFont)
                    .foregroundStyle(Theme.textTertiary)
                    .padding(.horizontal, 12)
                    .padding(.bottom, 4)
                ForEach(store.hosts) { host in
                    HStack(spacing: 6) {
                        if let brand = AgentBrand.forAgent(host.id) { AgentLogo(brand: brand, size: 12) }
                        Text(host.displayName)
                            .font(Theme.uiFont)
                            .foregroundStyle(Theme.textSecondary)
                    }
                    .padding(.horizontal, 12)
                    .padding(.vertical, 3)
                }
                .padding(.bottom, 10)
            }
        }
        .frame(width: 190)
        .background(Theme.sidebar)
    }

    private var header: some View {
        HStack(spacing: 8) {
            HerdIcon("magnifyingglass", size: 15)
                .foregroundStyle(Theme.textTertiary)
            TextField("Search \(store.section.title)", text: $store.query)
                .textFieldStyle(.plain)
                .font(Theme.uiFont)
                .foregroundStyle(Theme.textPrimary)
            if store.pendingReload {
                Button("Reload Agents") { store.reloadAgents() }
                    .controlSize(.small)
                    .help("Restart running agents with --resume so the new configuration loads")
            }
            Button {
                switch store.section {
                case .mcp: addingServer = true
                case .plugins: editing = LibraryDraft(kind: .prompt, marketplaceSource: true)
                case .skills: editing = LibraryDraft(kind: .skill)
                case .prompts: editing = LibraryDraft(kind: .prompt)
                }
            } label: {
                Label { Text(addTitle) } icon: { HerdIcon("plus", size: 13) }
            }
            .controlSize(.small)
            if store.section == .prompts {
                Button("Import…") { importPrompts() }
                    .controlSize(.small)
                    .help("Copy a folder of .md prompts into your library")
            }
            Button {
                store.section == .plugins ? store.loadPlugins(force: true) : store.refreshAll()
            } label: {
                HerdIcon("arrow.clockwise", size: 13)
            }
            .controlSize(.small)
            .help("Refresh")
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 9)
    }

    private func importPrompts() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.prompt = "Import"
        panel.message = "Choose a folder of .md prompts"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        store.importPrompts(from: url, installIn: store.hosts)
    }

    private var addTitle: String {
        switch store.section {
        case .mcp: "Add Server"
        case .plugins: "Add Marketplace"
        case .skills: "New Skill"
        case .prompts: "New Prompt"
        }
    }

    /// Plugins count as installed out of available; the rest count all.
    private func countLabel(of section: MarketplaceStore.Section) -> String? {
        let total = totalCount(of: section)
        guard total > 0 else { return nil }
        guard section == .plugins else { return "\(total)" }
        return "\(store.plugins.filter(\.isInstalled).count) / \(total)"
    }

    private func totalCount(of section: MarketplaceStore.Section) -> Int {
        switch section {
        case .mcp: store.servers.count
        case .plugins: store.plugins.count
        case .skills: store.skills.count
        case .prompts: store.prompts.count
        }
    }

    private func retry(_ section: MarketplaceStore.Section) {
        switch section {
        case .mcp: store.loadServers()
        case .plugins: store.loadPlugins(force: true)
        case .skills, .prompts: store.loadLibrary()
        }
    }

    @ViewBuilder
    private var content: some View {
        let section = store.section
        ScrollView {
            LazyVStack(spacing: 4) {
                let total = totalCount(of: section)
                if let error = store.loadErrors[section], total > 0 {
                    LoadErrorBanner(message: error, retrying: store.loading.contains(section)) { retry(section) }
                }
                switch section {
                case .mcp:
                    let servers = store.filteredServers()
                    if let state = emptyState(section, total: total, visible: servers.count) {
                        state
                    }
                    ForEach(servers) { entry in
                        EntryRow(store: store, entry: entry)
                    }
                case .plugins:
                    let plugins = store.filteredPlugins()
                    let limit = MarketplaceStore.pluginDisplayLimit
                    if let state = emptyState(section, total: total, visible: plugins.count) {
                        state
                    }
                    ForEach(plugins.prefix(limit)) { entry in
                        EntryRow(store: store, entry: entry)
                    }
                    if plugins.count > limit {
                        Text("Showing \(limit) of \(plugins.count). Refine your search.")
                            .font(Theme.captionFont)
                            .foregroundStyle(Theme.textTertiary)
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 10)
                    }
                case .skills, .prompts:
                    let kind: AgentLibrary.Kind = section == .skills ? .skill : .prompt
                    let items = store.filteredLibrary(kind)
                    if let state = emptyState(section, total: total, visible: items.count) {
                        state
                    }
                    ForEach(items) { item in
                        LibraryRow(store: store, item: item) {
                            editing = LibraryDraft(item: item, text: store.text(of: item))
                        }
                    }
                    ImportRow(store: store, kind: kind)
                }
            }
            .padding(10)
        }
        .background(Theme.terminalBackground)
    }

    /// What to show in place of an empty list, or nil when rows are showing.
    private func emptyState(_ section: MarketplaceStore.Section, total: Int, visible: Int) -> MarketplaceEmptyState? {
        guard visible == 0 else { return nil }
        let needsAgent = section == .mcp || section == .plugins
        let capable = store.hosts.contains { section == .mcp ? $0.supportsMCP : $0.supportsPlugins }
        if total == 0, store.loading.contains(section) || !store.loaded.contains(section) {
            return MarketplaceEmptyState(
                symbol: nil,
                title: "Loading \(section.title)",
                message: section == .plugins
                    ? "Fetching every configured marketplace. This can take a while the first time."
                    : "Asking each agent for its list."
            )
        }
        if total == 0, needsAgent, !capable {
            return MarketplaceEmptyState(
                symbol: "person.crop.circle.badge.questionmark",
                title: "No agents installed",
                message: "Herd found no agent on this Mac that manages \(section.title.lowercased()). Install Claude Code or Codex, then refresh."
            )
        }
        if total == 0, let error = store.loadErrors[section] {
            return MarketplaceEmptyState(
                symbol: "exclamationmark.triangle",
                title: "Couldn't load \(section.title)",
                message: error,
                actionTitle: "Retry"
            ) { retry(section) }
        }
        if total == 0 {
            switch section {
            case .mcp:
                return MarketplaceEmptyState(
                    symbol: section.symbol,
                    title: "No MCP servers yet",
                    message: "Add a server once and Herd installs it into each agent in its own syntax.",
                    actionTitle: "Add Server"
                ) { addingServer = true }
            case .plugins:
                return MarketplaceEmptyState(
                    symbol: section.symbol,
                    title: "No plugins available",
                    message: "Add a plugin marketplace to browse what it offers.",
                    actionTitle: "Add Marketplace"
                ) { editing = LibraryDraft(kind: .prompt, marketplaceSource: true) }
            case .skills:
                return MarketplaceEmptyState(
                    symbol: section.symbol,
                    title: "No skills yet",
                    message: "Skills in your library are linked into every agent you pick.",
                    actionTitle: "New Skill"
                ) { editing = LibraryDraft(kind: .skill) }
            case .prompts:
                return MarketplaceEmptyState(
                    symbol: section.symbol,
                    title: "No prompts yet",
                    message: "Prompts in your library become slash commands in every agent you pick.",
                    actionTitle: "New Prompt"
                ) { editing = LibraryDraft(kind: .prompt) }
            }
        }
        return MarketplaceEmptyState(
            symbol: "magnifyingglass",
            title: "No matches",
            message: "Nothing in \(section.title) matches \u{201C}\(store.query.trimmingCharacters(in: .whitespaces))\u{201D}.",
            actionTitle: "Clear Search"
        ) { store.query = "" }
    }
}

// MARK: - States

/// Stands in for an empty list: loading, failed, empty, or no matches.
private struct MarketplaceEmptyState: View {
    /// nil shows a spinner.
    let symbol: String?
    let title: String
    let message: String
    var actionTitle: String?
    var action: (() -> Void)?

    var body: some View {
        VStack(spacing: 10) {
            if let symbol {
                HerdIcon(symbol, size: 35)
                    .foregroundStyle(Theme.textTertiary)
            } else {
                LoadingLine(width: 48, thickness: 3)
            }
            Text(title)
                .font(.system(size: 14, weight: .semibold))
                .foregroundStyle(Theme.textPrimary)
            Text(message)
                .font(Theme.uiFont)
                .foregroundStyle(Theme.textSecondary)
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
                .textSelection(.enabled)
                .frame(maxWidth: 420)
            if let actionTitle, let action {
                Button(actionTitle, action: action)
                    .controlSize(.small)
                    .padding(.top, 2)
            }
        }
        .frame(maxWidth: .infinity)
        .padding(.top, 70)
        .padding(.bottom, 30)
        .padding(.horizontal, 20)
        .accessibilityElement(children: .contain)
    }
}

/// A failed refresh over a list that still shows its previous rows.
private struct LoadErrorBanner: View {
    let message: String
    let retrying: Bool
    let retry: () -> Void

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            HerdIcon("exclamationmark.triangle.fill", size: 16)
                .foregroundStyle(Theme.danger)
            VStack(alignment: .leading, spacing: 3) {
                Text("Couldn't refresh; showing what loaded before")
                    .font(Theme.uiFontMedium)
                    .foregroundStyle(Theme.textPrimary)
                Text(message)
                    .font(Theme.captionFont)
                    .foregroundStyle(Theme.textSecondary)
                    .textSelection(.enabled)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 8)
            if retrying {
                LoadingLine(width: 18)
            } else {
                Button("Retry", action: retry).controlSize(.small)
            }
        }
        .padding(10)
        .background(Theme.danger.opacity(0.12))
        .overlay(RoundedRectangle(cornerRadius: 6).strokeBorder(Theme.danger.opacity(0.5), lineWidth: 1))
        .clipShape(RoundedRectangle(cornerRadius: 6))
        .padding(.bottom, 4)
    }
}

// MARK: - Rows

private struct SidebarRow: View {
    let title: String
    let symbol: String
    let count: String?
    let selected: Bool
    let loading: Bool
    let action: () -> Void
    @State private var hovered = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: 8) {
                HerdIcon(symbol, size: 15)
                    .frame(width: 14)
                Text(title)
                    .font(selected ? Theme.uiFontMedium : Theme.uiFont)
                Spacer(minLength: 4)
                if loading {
                    LoadingLine(width: 14)
                } else if let count {
                    Text(count)
                        .font(Theme.captionFont)
                        .foregroundStyle(Theme.textTertiary)
                }
            }
            .foregroundStyle(selected ? Theme.textPrimary : Theme.textSecondary)
            .padding(.horizontal, 10)
            .padding(.vertical, 5)
            .background(selected ? Theme.cardSelected : (hovered ? Theme.hover : Color.clear))
            .clipShape(RoundedRectangle(cornerRadius: Theme.rowRadius))
        }
        .buttonStyle(.plain)
        .onHover { hovered = $0 }
        .padding(.horizontal, 6)
        .accessibilityAddTraits(selected ? .isSelected : [])
    }
}

/// A plugin or MCP server, with a chip per agent showing where it is installed.
private struct EntryRow: View {
    @ObservedObject var store: MarketplaceStore
    let entry: MarketplaceEntry
    @State private var hovered = false

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            HerdIcon(entry.kind == .mcp ? "point.3.connected.trianglepath.dotted" : "puzzlepiece.extension", size: 16)
                .foregroundStyle(entry.isInstalled ? Theme.accent : Theme.textTertiary)
                .frame(width: 16)
                .padding(.top, 2)
            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 6) {
                    Text(entry.name)
                        .font(Theme.uiFontMedium)
                        .foregroundStyle(Theme.textPrimary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                        .layoutPriority(1)
                    if !entry.version.isEmpty {
                        Text(entry.version).font(Theme.captionFont).foregroundStyle(Theme.textTertiary)
                    }
                    if let count = entry.installCount, count > 0 {
                        Text("\(count) installs").font(Theme.captionFont).foregroundStyle(Theme.textTertiary)
                    }
                    if !entry.marketplace.isEmpty {
                        Text(entry.marketplace).font(Theme.captionFont).foregroundStyle(Theme.textTertiary)
                    }
                }
                if !entry.summary.isEmpty || !entry.detail.isEmpty {
                    Text(entry.summary.isEmpty ? entry.detail : entry.summary)
                        .font(Theme.captionFont)
                        .foregroundStyle(Theme.textSecondary)
                        .lineLimit(2)
                }
                HStack(spacing: 6) {
                    ForEach(store.hosts) { host in
                        HostChip(
                            host: host,
                            installed: entry.installedIn.contains(host.id),
                            enabled: entry.enabledIn.contains(host.id),
                            status: entry.status[host.id],
                            busy: store.isBusy(entry, host)
                        ) {
                            toggle(host)
                        }
                    }
                }
            }
            Spacer(minLength: 8)
            if entry.isInstalled {
                Button("Remove") {
                    let hosts = store.hosts.filter { entry.installedIn.contains($0.id) }
                    ConfirmCenter.shared.ask(
                        title: "Remove \(entry.name)?",
                        message: "Removes it from \(hosts.map(\.displayName).joined(separator: ", ")).",
                        confirmTitle: "Remove",
                        destructive: true
                    ) { _ in store.remove(entry, from: hosts) }
                }
                .controlSize(.small)
                .opacity(hovered ? 1 : 0.5)
                .disabled(store.isBusy(entry))
            }
        }
        .padding(10)
        .background(hovered ? Theme.hover : Theme.card)
        .clipShape(RoundedRectangle(cornerRadius: 6))
        .onHover { hovered = $0 }
    }

    private func toggle(_ host: AgentHost) {
        if entry.installedIn.contains(host.id) {
            store.remove(entry, from: [host])
        } else {
            store.add(entry, to: [host])
        }
    }
}

/// One agent's install state for an item; click to add or remove it there.
private struct HostChip: View {
    let host: AgentHost
    let installed: Bool
    var enabled = true
    var status: String?
    /// A change for this host is running: spin and ignore clicks.
    var busy = false
    let toggle: () -> Void
    @State private var hovered = false

    var body: some View {
        Button(action: toggle) {
            HStack(spacing: 4) {
                if busy {
                    LoadingLine(width: 10)
                } else if let brand = AgentBrand.forAgent(host.id) {
                    AgentLogo(brand: brand, size: 10)
                } else {
                    HerdIcon("terminal", size: 12)
                }
                Text(host.displayName)
                    .font(Theme.captionFont)
                if let status, status.contains("✘") || status == "disabled" {
                    HerdIcon("exclamationmark.triangle.fill", size: 11)
                        .foregroundStyle(.orange)
                }
            }
            .foregroundStyle(installed ? Theme.textPrimary : Theme.textTertiary)
            .padding(.horizontal, 7)
            .padding(.vertical, 3)
            .background {
                let tint = AgentBrand.forAgent(host.id)?.hueHex.map { Color(hex: $0) } ?? Theme.accent
                RoundedRectangle(cornerRadius: 10)
                    .fill(installed ? tint.opacity(enabled ? 0.22 : 0.1) : Color.clear)
                RoundedRectangle(cornerRadius: 10)
                    .strokeBorder(installed ? tint.opacity(0.5) : Theme.border, lineWidth: 1)
            }
            .opacity(hovered ? 0.85 : 1)
        }
        .buttonStyle(.plain)
        .disabled(busy)
        .onHover { hovered = $0 }
        .help(busy ? "Updating \(host.displayName)…" : status ?? (installed ? "Installed in \(host.displayName)" : "Add to \(host.displayName)"))
        .accessibilityLabel(host.displayName)
        .accessibilityValue(busy ? "Updating" : installed ? "Installed" : "Not installed")
    }
}

private struct LibraryRow: View {
    @ObservedObject var store: MarketplaceStore
    let item: AgentLibrary.Item
    let edit: () -> Void
    @State private var hovered = false

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            HerdIcon(item.kind == .skill ? "graduationcap" : "text.bubble", size: 16)
                .foregroundStyle(item.installedIn.isEmpty ? Theme.textTertiary : Theme.accent)
                .frame(width: 16)
                .padding(.top, 2)
            VStack(alignment: .leading, spacing: 3) {
                Text(item.name)
                    .font(Theme.uiFontMedium)
                    .foregroundStyle(Theme.textPrimary)
                if !item.summary.isEmpty {
                    Text(item.summary)
                        .font(Theme.captionFont)
                        .foregroundStyle(Theme.textSecondary)
                        .lineLimit(2)
                }
                HStack(spacing: 6) {
                    ForEach(store.hosts) { host in
                        HostChip(host: host, installed: item.installedIn.contains(host.id)) {
                            store.setLibraryInstalled(item, host: host, installed: !item.installedIn.contains(host.id))
                        }
                    }
                }
            }
            Spacer(minLength: 8)
            HStack(spacing: 4) {
                if item.kind == .prompt, let agent = store.promptTarget {
                    Button("Run") { store.runPrompt(item) }
                        .controlSize(.small)
                        .help("Send this prompt to \(AgentBrand.forAgent(agent.agent)?.displayName ?? "the focused agent")")
                }
                Button("Edit", action: edit).controlSize(.small)
                Button("Delete") {
                    ConfirmCenter.shared.ask(
                        title: "Delete \(item.name)?",
                        message: "Deletes it from the library and uninstalls it from every agent that has it. This can't be undone.",
                        confirmTitle: "Delete",
                        destructive: true
                    ) { _ in store.deleteLibraryItem(item) }
                }
                .controlSize(.small)
            }
            .opacity(hovered ? 1 : 0.5)
        }
        .padding(10)
        .background(hovered ? Theme.hover : Theme.card)
        .clipShape(RoundedRectangle(cornerRadius: 6))
        .onHover { hovered = $0 }
    }
}

/// Offers to pull an agent's own skills and prompts into the shared library.
private struct ImportRow: View {
    @ObservedObject var store: MarketplaceStore
    let kind: AgentLibrary.Kind

    var body: some View {
        let groups = store.unmanaged(kind)
        if !groups.isEmpty {
            VStack(alignment: .leading, spacing: 6) {
                Text("In your agents but not in the library")
                    .font(Theme.headerFont)
                    .foregroundStyle(Theme.textTertiary)
                ForEach(groups, id: \.host.id) { group in
                    ForEach(group.slugs, id: \.self) { slug in
                        HStack(spacing: 8) {
                            Text(slug).font(Theme.uiFont).foregroundStyle(Theme.textSecondary)
                            Text(group.host.displayName).font(Theme.captionFont).foregroundStyle(Theme.textTertiary)
                            Spacer()
                            Button("Add to Library") { store.adopt(kind: kind, slug: slug, from: group.host) }
                                .controlSize(.small)
                        }
                    }
                }
            }
            .padding(10)
            .background(Theme.card.opacity(0.6))
            .clipShape(RoundedRectangle(cornerRadius: 6))
        }
    }
}

// MARK: - Editors

struct LibraryDraft: Identifiable {
    let id = UUID()
    var kind: AgentLibrary.Kind
    var slug = ""
    var text = ""
    var hosts: Set<String> = []
    var isNew = true
    /// Reuses the sheet to add a plugin marketplace instead.
    var marketplaceSource = false

    init(kind: AgentLibrary.Kind, marketplaceSource: Bool = false) {
        self.kind = kind
        self.marketplaceSource = marketplaceSource
        text = kind == .skill
            ? "---\nname: my-skill\ndescription: What this skill is for, and when to use it\n---\n\n# My Skill\n\nSteps the agent should follow.\n"
            : "---\ndescription: What this prompt does\n---\n\nWrite the prompt here.\n"
    }

    init(item: AgentLibrary.Item, text: String) {
        kind = item.kind
        slug = item.slug
        self.text = text
        hosts = item.installedIn
        isNew = false
    }
}

private struct LibraryEditor: View {
    @ObservedObject var store: MarketplaceStore
    @State var draft: LibraryDraft
    let close: () -> Void
    @State private var source = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(title).font(Theme.uiFontMedium).foregroundStyle(Theme.textPrimary)
            if draft.marketplaceSource {
                Text("A GitHub repo, URL, or local path holding a plugin marketplace.")
                    .font(Theme.captionFont).foregroundStyle(Theme.textSecondary)
                TextField("owner/repo", text: $source)
                    .textFieldStyle(.roundedBorder)
                hostPicker
            } else {
                TextField("name", text: $draft.slug)
                    .textFieldStyle(.roundedBorder)
                    .disabled(!draft.isNew)
                TextEditor(text: $draft.text)
                    .font(Theme.monoFont)
                    .frame(minHeight: 260)
                    .overlay(RoundedRectangle(cornerRadius: 4).strokeBorder(Theme.border, lineWidth: 1))
                hostPicker
            }
            HStack {
                Button("Cancel", action: close).keyboardShortcut(.cancelAction)
                Spacer()
                Button("Save", action: save)
                    .keyboardShortcut(.defaultAction)
                    .disabled(draft.marketplaceSource ? source.isEmpty : draft.slug.isEmpty)
            }
        }
        .padding(16)
        .frame(width: 520)
        .background(Theme.chrome)
    }

    private var title: String {
        if draft.marketplaceSource { return "Add a plugin marketplace" }
        let noun = draft.kind == .skill ? "skill" : "prompt"
        return draft.isNew ? "New \(noun)" : "Edit \(draft.slug)"
    }

    private var hostPicker: some View {
        HStack(spacing: 8) {
            Text("Install in").font(Theme.captionFont).foregroundStyle(Theme.textTertiary)
            ForEach(store.hosts) { host in
                HostChip(host: host, installed: draft.hosts.contains(host.id)) {
                    if draft.hosts.contains(host.id) { draft.hosts.remove(host.id) } else { draft.hosts.insert(host.id) }
                }
            }
        }
    }

    private func save() {
        let hosts = store.hosts.filter { draft.hosts.contains($0.id) }
        if draft.marketplaceSource {
            store.addMarketplace(source.trimmingCharacters(in: .whitespaces), to: hosts.isEmpty ? store.hosts : hosts)
            close()
            return
        }
        let slug = draft.slug.trimmingCharacters(in: .whitespaces)
            .replacingOccurrences(of: " ", with: "-")
            .lowercased()
        if store.saveLibraryItem(kind: draft.kind, slug: slug, text: draft.text, installIn: hosts) {
            // Links for hosts that were unchecked are removed too.
            if let item = (draft.kind == .skill ? store.skills : store.prompts).first(where: { $0.slug == slug }) {
                for host in store.hosts where !draft.hosts.contains(host.id) && item.installedIn.contains(host.id) {
                    store.setLibraryInstalled(item, host: host, installed: false)
                }
            }
            close()
        }
    }
}

private struct ServerEditor: View {
    @ObservedObject var store: MarketplaceStore
    let close: () -> Void
    @State private var name = ""
    @State private var command = ""
    @State private var hosts: Set<String> = []
    @State private var submitting = false
    @State private var error: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Add an MCP server").font(Theme.uiFontMedium).foregroundStyle(Theme.textPrimary)
            Text("A command to run, or an HTTP URL. Herd adds it in each agent's own syntax.")
                .font(Theme.captionFont).foregroundStyle(Theme.textSecondary)
            TextField("name", text: $name).textFieldStyle(.roundedBorder)
                .disabled(submitting)
            TextField("npx -y @acme/mcp-server  ·  https://mcp.example.com/mcp", text: $command)
                .textFieldStyle(.roundedBorder)
                .font(Theme.monoFont)
                .disabled(submitting)
            HStack(spacing: 8) {
                Text("Add to").font(Theme.captionFont).foregroundStyle(Theme.textTertiary)
                ForEach(store.hosts) { host in
                    HostChip(host: host, installed: hosts.contains(host.id)) {
                        if hosts.contains(host.id) { hosts.remove(host.id) } else { hosts.insert(host.id) }
                    }
                }
            }
            .disabled(submitting)
            if let error {
                HStack(alignment: .top, spacing: 6) {
                    HerdIcon("exclamationmark.triangle.fill", size: 14)
                        .foregroundStyle(Theme.danger)
                    Text(error)
                        .font(Theme.captionFont)
                        .foregroundStyle(Theme.danger)
                        .textSelection(.enabled)
                        .fixedSize(horizontal: false, vertical: true)
                }
                .accessibilityElement(children: .combine)
            }
            HStack {
                Button("Cancel", action: close).keyboardShortcut(.cancelAction)
                Spacer()
                if submitting {
                    LoadingLine(width: 18)
                    Text("Adding…").font(Theme.captionFont).foregroundStyle(Theme.textSecondary)
                }
                Button("Add", action: add)
                    .keyboardShortcut(.defaultAction)
                    .disabled(submitting || name.trimmingCharacters(in: .whitespaces).isEmpty
                        || command.trimmingCharacters(in: .whitespaces).isEmpty)
            }
        }
        .padding(16)
        .frame(width: 520)
        .background(Theme.chrome)
        .onAppear { hosts = Set(store.hosts.map(\.id)) }
    }

    /// Stays open until the agents answer, so a failed command can be fixed
    /// instead of retyped.
    private func add() {
        let targets = store.hosts.filter { hosts.contains($0.id) }
        submitting = true
        error = nil
        store.addServer(name: name.trimmingCharacters(in: .whitespaces),
                        command: command,
                        into: targets.isEmpty ? store.hosts : targets) { failure in
            submitting = false
            if let failure {
                error = failure
            } else {
                close()
            }
        }
    }
}
