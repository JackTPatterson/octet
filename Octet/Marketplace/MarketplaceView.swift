import AppKit
import SwiftUI

/// Browse and install MCP servers, plugins, skills and prompts for every
/// agent from one page, then reload running agents in place. Settings'
/// sibling: the same section list with search on the left, the same 52pt
/// breadcrumb header, and the section as a centred column of titled cards.
/// A page over the window with `close`; on its own, the Marketplace window
/// it falls back to with no main window open.
struct MarketplaceView: View {
    @ObservedObject var store: MarketplaceStore
    /// Set when the Marketplace is a page over the window, as Settings is.
    var close: (() -> Void)?
    @ObservedObject private var pluginHost = OctetPluginHost.shared
    /// The editor showing over the page, if any.
    @State private var editor: MarketplaceEditorKind?
    /// The row showing its details.
    @State private var expanded: String?
    /// How many rows each long group shows, by group id.
    @State private var limits: [String: Int] = [:]
    @State private var marketplacesOpen = false
    @FocusState private var focus: Focus?

    private enum Focus: Hashable { case search, sections }
    private var embedded: Bool { close != nil }

    var body: some View {
        HStack(spacing: 0) {
            nav
            Rectangle().fill(Theme.divider).frame(width: 1)
            VStack(spacing: 0) {
                header
                if store.section == .plugins, store.agentFilter == nil {
                    PluginSourceTabs(store: store, agentCount: store.plugins.count, terminalCount: terminalPluginCount)
                }
                content
            }
            .background(Theme.terminalBackground)
        }
        .overlay { editorOverlay }
        .modifier(MarketplaceChrome(embedded: embedded))
        .defaultFocus($focus, .sections)
        .onAppear(perform: appeared)
        .onKeyPress(KeyEquivalent("/")) {
            guard focus != .search, editor == nil else { return .ignored }
            focus = .search
            return .handled
        }
        .onExitCommand(perform: escape)
        // A new list starts at its top, folded, one page long.
        .onChange(of: store.section) { _, _ in reset() }
        .onChange(of: store.query) { _, _ in reset() }
        .onChange(of: store.agentFilter) { _, _ in reset() }
        .onChange(of: store.sort) { _, _ in reset() }
        .onChange(of: store.pluginFilter) { _, _ in reset() }
    }

    private func appeared() {
        store.refreshAll()
        focus = .sections
        #if DEBUG
        if let name = ProcessInfo.processInfo.environment["OCTET_MARKETPLACE_SECTION"],
           let section = MarketplaceStore.Section(rawValue: name) {
            store.section = section
        }
        #endif
    }

    private func reset() {
        expanded = nil
        limits = [:]
    }

    /// Esc closes what's on top: an editor, then the search, then the page.
    private func escape() {
        if editor != nil {
            editor = nil
        } else if !store.query.isEmpty {
            store.query = ""
        } else if expanded != nil {
            expanded = nil
        } else {
            close?()
        }
    }

    // MARK: Nav

    private var nav: some View {
        VStack(alignment: .leading, spacing: 8) {
            SettingsSearchField(
                query: $store.query, label: "Search \(store.section.title)",
                focus: $focus, focusValue: .search,
                submit: { focus = .sections }, move: { _ in },
                // Esc in an empty search closes what's open, as it does elsewhere on the page.
                clear: { if store.query.isEmpty { escape() } else { store.query = "" } }
            )
            .padding(.horizontal, 8)
            ScrollView {
                VStack(alignment: .leading, spacing: 2) {
                    ForEach(MarketplaceStore.Section.allCases) { section in
                        MarketplaceNavRow(mark: .symbol(section.symbol), title: section.title,
                                          count: countLabel(of: section),
                                          loading: store.loading.contains(section),
                                          selected: store.section == section) {
                            store.section = section
                        }
                    }
                    if store.hosts.isEmpty, !store.loaded.contains(store.section) || !store.loading.isEmpty {
                        // The agents aren't known yet: their rows hold the
                        // place, so the list doesn't pop in under the sections.
                        Text("Agents")
                            .font(Theme.interfaceFont(11, weight: .medium))
                            .foregroundStyle(Theme.textTertiary)
                            .padding(.horizontal, 10)
                            .padding(.top, 18)
                            .padding(.bottom, 4)
                        ForEach(0..<5, id: \.self) { index in
                            HStack(spacing: 8) {
                                SkeletonBlock(width: 18, height: 14, radius: 4)
                                SkeletonBlock(width: [96, 70, 84, 60, 78][index], height: 10, radius: 5)
                                Spacer(minLength: 4)
                                SkeletonBlock(width: 16, height: 9, radius: 4)
                            }
                            .padding(.horizontal, 10)
                            .frame(height: 30)
                        }
                        .accessibilityHidden(true)
                    }
                    if !store.hosts.isEmpty {
                        Text("Agents")
                            .font(Theme.interfaceFont(11, weight: .medium))
                            .foregroundStyle(Theme.textTertiary)
                            .padding(.horizontal, 10)
                            .padding(.top, 18)
                            .padding(.bottom, 4)
                            .accessibilityAddTraits(.isHeader)
                        MarketplaceNavRow(mark: .symbol("person.2"), title: "All Agents", count: nil, loading: false,
                                          selected: store.agentFilter == nil) {
                            store.agentFilter = nil
                        }
                        ForEach(store.hosts) { host in
                            MarketplaceNavRow(mark: .agent(host.id), title: host.displayName,
                                              count: "\(store.installedCount(store.section, in: host))", loading: false,
                                              selected: store.agentFilter == host.id) {
                                store.agentFilter = store.agentFilter == host.id ? nil : host.id
                            }
                            .help("Show what \(host.displayName) has, and what it could add")
                        }
                    }
                }
                .padding(.horizontal, 8)
                .padding(.bottom, 12)
            }
            .scrollIndicators(.never)
            .focusable()
            .focusEffectDisabled()
            .focused($focus, equals: .sections)
            .onKeyPress(.downArrow) { step(1); return .handled }
            .onKeyPress(.upArrow) { step(-1); return .handled }
            .accessibilityElement(children: .contain)
            .accessibilityLabel("Marketplace sections")
        }
        .padding(.top, embedded ? 12 : 44)
        .frame(width: 220)
        .frame(maxHeight: .infinity, alignment: .top)
        .background(Theme.sidebar)
    }

    private func step(_ delta: Int) {
        let all = MarketplaceStore.Section.allCases
        guard let index = all.firstIndex(of: store.section) else { return }
        store.section = all[(index + delta + all.count) % all.count]
    }

    /// Plugins count as installed out of available; the rest count all.
    private func countLabel(of section: MarketplaceStore.Section) -> String? {
        let total = totalCount(of: section)
        guard total > 0 else { return nil }
        guard section == .plugins else { return "\(total)" }
        return "\(store.installedPluginCount + pluginHost.plugins.count) / \(total.formatted())"
    }

    private func totalCount(of section: MarketplaceStore.Section) -> Int {
        switch section {
        case .mcp: store.servers.count
        case .plugins: store.plugins.count + terminalPluginCount
        case .skills: store.skills.count
        case .prompts: store.prompts.count
        }
    }

    /// Octet's own plugins, built in, installed or listed.
    private var terminalPluginCount: Int {
        Set(pluginHost.plugins.map(\.id)).union(pluginHost.registry.map(\.id)).count
    }

    private var filteredHost: AgentHost? {
        store.agentFilter.flatMap { id in store.hosts.first { $0.id == id } }
    }

    // MARK: Header

    /// "Marketplace / Plugins", Settings' header, with the section's
    /// actions at the far end and the close button after them.
    private var header: some View {
        HStack(spacing: 8) {
            Text("Marketplace").foregroundStyle(Theme.textTertiary)
            Text("/").foregroundStyle(Theme.textMuted).accessibilityHidden(true)
            Text(store.section.title)
                .foregroundStyle(filteredHost == nil ? Theme.textPrimary : Theme.textTertiary)
                .accessibilityAddTraits(filteredHost == nil ? .isHeader : [])
            if let host = filteredHost {
                Text("/").foregroundStyle(Theme.textMuted).accessibilityHidden(true)
                AgentCrumb(host: host) { store.agentFilter = nil }
            }
            Spacer(minLength: 12)
            actions
            if let close {
                OctetIconButton(icon: "xmark", help: "Close Marketplace (Esc)", action: close)
            }
        }
        .font(Theme.interfaceFont(13, weight: .medium))
        .lineLimit(1)
        .padding(.horizontal, 24)
        .frame(height: 52)
        .frame(maxWidth: .infinity)
    }

    /// Reload, import, add and refresh, for the section in view.
    @ViewBuilder private var actions: some View {
        if store.reloading {
            HStack(spacing: 6) {
                LoadingLine(width: 16)
                Text("Reloading agents…").font(Theme.uiFont).foregroundStyle(Theme.textSecondary)
            }
            .accessibilityElement(children: .combine)
        } else if store.pendingReload {
            OctetButton(title: "Reload Agents", icon: "arrow.clockwise", kind: .primary, compact: true) { store.reloadAgents() }
                .help("Restart running agents with --resume so the new configuration loads")
        }
        if store.section == .prompts {
            OctetButton(title: "Import…", icon: "square.and.arrow.down", kind: .ghost, compact: true) { importPrompts() }
                .help("Copy a folder of .md prompts into your library")
        }
        OctetButton(title: addTitle, icon: "plus", compact: true, action: add)
        if store.loading.contains(store.section) || (store.section == .plugins && pluginHost.registryLoading) {
            LoadingLine(width: 16)
                .frame(width: 24, height: 24)
                .help("Refreshing…")
        } else {
            OctetIconButton(icon: "arrow.clockwise", help: "Refresh \(store.section.title)", action: refresh)
        }
    }

    private var addTitle: String {
        switch store.section {
        case .mcp: "Add Server"
        case .plugins: "Add Marketplace"
        case .skills: "New Skill"
        case .prompts: "New Prompt"
        }
    }

    private func add() {
        switch store.section {
        case .mcp: editor = .server
        case .plugins: editor = .library(LibraryDraft(kind: .prompt, marketplaceSource: true))
        case .skills: editor = .library(LibraryDraft(kind: .skill))
        case .prompts: editor = .library(LibraryDraft(kind: .prompt))
        }
    }

    private func refresh() {
        switch store.section {
        case .mcp: store.loadServers()
        case .plugins:
            store.loadPlugins(force: true)
            pluginHost.loadRegistry(force: true)
        case .skills, .prompts:
            store.loadLibrary()
        }
    }

    private func importPrompts() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.prompt = "Import"
        panel.message = "Choose a folder of .md prompts"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        store.importPrompts(from: url, installIn: store.scopeHosts(for: .prompts))
    }

    // MARK: Content

    private var content: some View {
        ScrollView {
            // Settings' readable column: 896pt at most, centred.
            LazyVStack(alignment: .leading, spacing: 0) {
                banners
                switch store.section {
                case .mcp: serverSection
                case .plugins: pluginSection
                case .skills: librarySection(.skill)
                case .prompts: librarySection(.prompt)
                }
            }
            .padding(.horizontal, 24)
            .padding(.bottom, 48)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .octetScrollIndicators()
        .id(store.section)
    }

    @ViewBuilder private var banners: some View {
        let section = store.section
        if let error = store.loadErrors[section], totalCount(of: section) > 0 {
            MarketplaceBanner(tone: .danger, icon: "exclamationmark.triangle.fill",
                              title: "Couldn't refresh; showing what loaded before", message: error) {
                if store.loading.contains(section) {
                    LoadingLine(width: 18)
                } else {
                    OctetButton(title: "Retry", compact: true) { retry(section) }
                }
            }
            .padding(.top, 24)
        }
        if section == .plugins, store.pluginFilter != .agents, store.agentFilter == nil {
            if !pluginHost.updates.isEmpty {
                let updates = pluginHost.updates
                MarketplaceBanner(tone: .accent, icon: "arrow.down",
                                  title: updates.count == 1 ? "An update for \(updates[0].name)" : "\(updates.count) plugin updates",
                                  message: updates.map { "\($0.name) \($0.version)" }.joined(separator: ", ")) {
                    OctetButton(title: updates.count == 1 ? "Update" : "Update All", kind: .primary, compact: true) {
                        pluginHost.update(updates)
                    }
                    .disabled(!pluginHost.installing.isEmpty)
                }
                .padding(.top, 24)
            }
            if let error = pluginHost.registryError {
                MarketplaceBanner(tone: .danger, icon: "exclamationmark.triangle.fill",
                                  title: "Couldn't load terminal plugins", message: error) {
                    if pluginHost.registryLoading {
                        LoadingLine(width: 18)
                    } else {
                        OctetButton(title: "Retry", compact: true) { pluginHost.loadRegistry(force: true) }
                    }
                }
                .padding(.top, 24)
            }
        }
    }

    private func retry(_ section: MarketplaceStore.Section) {
        switch section {
        case .mcp: store.loadServers()
        case .plugins: store.loadPlugins(force: true)
        case .skills, .prompts: store.loadLibrary()
        }
    }

    // MARK: Sections

    @ViewBuilder private var serverSection: some View {
        let groups = store.serverGroups()
        if let state = emptyState(.mcp, total: store.servers.count, visible: groups.count) {
            state
        } else {
            let host = filteredHost
            group("mcp.installed", title: host.map { "In \($0.displayName)" } ?? "Installed", items: groups.installed,
                  empty: "No servers in \(host?.displayName ?? "any agent") match.") { entry in
                EntryRow(store: store, entry: entry, expanded: expandedBinding(entry.id))
            }
            if host != nil {
                group("mcp.available", title: "In Other Agents", items: groups.available,
                      empty: "Every server your agents have is in \(host?.displayName ?? "this agent") too.") { entry in
                    EntryRow(store: store, entry: entry, expanded: expandedBinding(entry.id))
                }
            }
        }
    }

    @ViewBuilder private var pluginSection: some View {
        let filter = store.agentFilter == nil ? store.pluginFilter : .agents
        let agent = filter == .terminal ? MarketplaceStore.Groups<MarketplaceEntry>() : store.pluginGroups()
        let terminal = filter == .agents ? MarketplaceStore.Groups<MarketplaceStore.TerminalPlugin>() : store.terminalPluginGroups()
        // What the filter can show, so the empty state reads right.
        let shown = (filter == .terminal ? 0 : store.plugins.count) + (filter == .agents ? 0 : terminalPluginCount)
        let agentLoading = filter != .terminal && store.plugins.isEmpty
            && (store.loading.contains(.plugins) || !store.loaded.contains(.plugins))
        if let state = emptyState(.plugins, total: shown, visible: agent.count + terminal.count) {
            state
        } else if agentLoading {
            // Octet's own plugins are in hand; the agents' catalog isn't yet.
            MarketplaceSkeleton(title: "Loading Agent Plugins",
                                detail: "Fetching every configured marketplace. This can take a while the first time.")
            if filter != .agents {
                group("terminal.installed", title: "Terminal Plugins", items: terminal.installed + terminal.available) { plugin in
                    TerminalPluginRow(plugin: plugin, expanded: expandedBinding("terminal:" + plugin.id))
                }
            }
        } else {
            if filter != .terminal {
                group("plugins.installed", title: filteredHost.map { "In \($0.displayName)" } ?? "Installed",
                      items: agent.installed, empty: emptyInstalledMessage) { entry in
                    EntryRow(store: store, entry: entry, expanded: expandedBinding(entry.id))
                }
            }
            if filter != .agents {
                group("terminal.installed", title: filter == .terminal ? "Installed" : "Terminal Plugins",
                      items: terminal.installed + (filter == .all ? terminal.available : []),
                      empty: emptyInstalledMessage) { plugin in
                    TerminalPluginRow(plugin: plugin, expanded: expandedBinding("terminal:" + plugin.id))
                }
            }
            if filter == .terminal {
                group("terminal.available", title: "Discover", items: terminal.available,
                      empty: "Every terminal plugin in the registry is installed.") { plugin in
                    TerminalPluginRow(plugin: plugin, expanded: expandedBinding("terminal:" + plugin.id))
                }
            }
            if filter != .terminal {
                group("plugins.available", title: "Discover", items: agent.available,
                      empty: store.query.isEmpty ? "Every plugin on offer is installed." : "Nothing else matches.") {
                    OctetSelect(selection: $store.sort,
                                options: MarketplaceStore.SortOrder.allCases.map { (value: $0, title: $0.title) })
                        .help("Order the plugins on offer")
                } row: { entry in
                    EntryRow(store: store, entry: entry, expanded: expandedBinding(entry.id))
                }
                if store.query.isEmpty, !store.marketplaces.isEmpty {
                    marketplaceSources
                }
            }
        }
    }

    /// The plugin marketplaces each agent pulls from.
    @ViewBuilder private var marketplaceSources: some View {
        let sources = marketplaceList()
        OctetCollapsible(title: "Marketplaces · \(sources.count)", open: $marketplacesOpen) {
            VStack(spacing: 0) {
                ForEach(Array(sources.enumerated()), id: \.element.source) { index, item in
                    HStack(spacing: 12) {
                        VStack(alignment: .leading, spacing: 3) {
                            Text(item.source.name)
                                .font(Theme.interfaceFont(13, weight: .medium))
                                .foregroundStyle(Theme.textPrimary)
                            if !item.source.source.isEmpty {
                                Text(item.source.source)
                                    .font(Theme.interfaceFont(12))
                                    .foregroundStyle(Theme.textSecondary)
                                    .textSelection(.enabled)
                            }
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                        AgentChips(hosts: store.hosts.filter { item.hosts.contains($0.id) }, installedIn: item.hosts)
                    }
                    .padding(.horizontal, 16)
                    .padding(.vertical, 10)
                    .cardSlot(.at(index, of: sources.count))
                }
            }
        }
        .padding(.top, 20)
    }

    /// Each configured marketplace once, with the agents that have it.
    private func marketplaceList() -> [(source: MarketplaceStore.MarketplaceSource, hosts: Set<String>)] {
        var byHost: [MarketplaceStore.MarketplaceSource: Set<String>] = [:]
        for (host, list) in store.marketplaces {
            for source in list { byHost[source, default: []].insert(host) }
        }
        return byHost.map { (source: $0.key, hosts: $0.value) }
            .sorted { $0.source.name.localizedCaseInsensitiveCompare($1.source.name) == .orderedAscending }
    }

    @ViewBuilder private func librarySection(_ kind: AgentLibrary.Kind) -> some View {
        let section: MarketplaceStore.Section = kind == .skill ? .skills : .prompts
        let groups = store.libraryGroups(kind)
        let unmanaged = store.unmanaged(kind).flatMap { group in group.slugs.map { UnmanagedItem(host: group.host, slug: $0) } }
            .filter { MarketplaceCatalog.searchRank(store.query, names: [$0.slug], texts: []) != nil }
            .filter { item in store.agentFilter.map { item.host.id == $0 } ?? true }
        let noun = kind == .skill ? "skill" : "prompt"
        if let state = emptyState(section, total: totalCount(of: section) + unmanaged.count, visible: groups.count + unmanaged.count) {
            state
        } else {
            group("\(noun).installed", title: filteredHost.map { "In \($0.displayName)" } ?? "Installed",
                  items: groups.installed, empty: emptyInstalledMessage) { item in
                LibraryRow(store: store, item: item, expanded: expandedBinding(item.id)) {
                    editor = .library(LibraryDraft(item: item, text: store.text(of: item)))
                }
            }
            if !groups.available.isEmpty {
                group("\(noun).available", title: filteredHost.map { "Not in \($0.displayName)" } ?? "In Your Library",
                      items: groups.available) { item in
                    LibraryRow(store: store, item: item, expanded: expandedBinding(item.id)) {
                        editor = .library(LibraryDraft(item: item, text: store.text(of: item)))
                    }
                }
            }
            if !unmanaged.isEmpty {
                group("\(noun).unmanaged", title: "In Your Agents, Not in the Library", items: unmanaged) { item in
                    UnmanagedRow(store: store, kind: kind, item: item)
                }
            }
        }
    }

    private var emptyInstalledMessage: String {
        let query = store.query.trimmingCharacters(in: .whitespaces)
        if !query.isEmpty { return "Nothing installed matches \u{201C}\(query)\u{201D}." }
        return "Nothing installed\(filteredHost.map { " in \($0.displayName)" } ?? "") yet."
    }

    private func expandedBinding(_ id: String) -> Binding<Bool> {
        Binding(
            get: { expanded == id },
            set: { open in MotionPreferences.shared.perform(.sidebar) { expanded = open ? id : nil } }
        )
    }

    // MARK: Groups

    /// A titled card of rows, as Settings draws them, showing a page at a
    /// time so a catalog of thousands stays quick.
    @ViewBuilder
    private func group<Item: Identifiable, Trailing: View, Row: View>(
        _ id: String, title: String, items: [Item], empty: String? = nil,
        @ViewBuilder trailing: () -> Trailing, @ViewBuilder row: @escaping (Item) -> Row
    ) -> some View {
        if !items.isEmpty || empty != nil {
            let limit = limits[id] ?? MarketplaceStore.pageSize
            let shown = Array(items.prefix(limit))
            let more = items.count > shown.count
            let slots = shown.count + (more ? 1 : 0)
            let control = trailing()
            MarketplaceGroupHeader(title: title, count: items.count) { control }
            if items.isEmpty, let empty {
                Text(empty)
                    .font(Theme.interfaceFont(12))
                    .foregroundStyle(Theme.textTertiary)
                    .padding(.horizontal, 16)
                    .padding(.vertical, 14)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .cardSlot(.only)
            }
            ForEach(Array(shown.enumerated()), id: \.element.id) { index, item in
                row(item).cardSlot(.at(index, of: slots))
            }
            if more {
                ShowMoreRow(shown: shown.count, total: items.count) {
                    limits[id] = limit + MarketplaceStore.pageSize
                }
                .cardSlot(.last)
            }
        }
    }

    @ViewBuilder
    private func group<Item: Identifiable, Row: View>(
        _ id: String, title: String, items: [Item], empty: String? = nil, @ViewBuilder row: @escaping (Item) -> Row
    ) -> some View {
        group(id, title: title, items: items, empty: empty, trailing: { EmptyView() }, row: row)
    }

    // MARK: Empty states

    /// What to show in place of a section's groups, or nil when there are
    /// rows (or groups worth showing empty).
    private func emptyState(_ section: MarketplaceStore.Section, total: Int, visible: Int) -> AnyView? {
        if total == 0, store.loading.contains(section) || !store.loaded.contains(section) {
            return AnyView(MarketplaceSkeleton(title: "Loading \(section.title)",
                                               detail: section == .plugins
                                                   ? "Fetching every configured marketplace. This can take a while the first time."
                                                   : "Asking each agent for its list."))
        }
        let capable = !store.capableHosts(for: section).isEmpty
        if total == 0, section == .mcp || section == .plugins, !capable {
            return AnyView(MarketplaceEmptyState(
                symbol: "person.2",
                title: "No agents to manage \(section.title.lowercased())",
                message: "Octet found no agent on this Mac whose CLI manages \(section.title.lowercased()). Install Claude Code or Codex, then refresh."
            ))
        }
        if let host = filteredHost, section == .mcp || section == .plugins, store.scopeHosts(for: section).isEmpty {
            return AnyView(MarketplaceEmptyState(
                symbol: section.symbol,
                title: "\(host.displayName) doesn't manage \(section.title.lowercased()) here",
                message: "Octet can only add \(section.title.lowercased()) through an agent's own CLI, and \(host.displayName)'s has no command for it.",
                actionTitle: "Show All Agents"
            ) { store.agentFilter = nil })
        }
        if total == 0, let error = store.loadErrors[section] {
            // The first line says why; the whole output is behind Copy Details.
            let reason = error.split(whereSeparator: \.isNewline).first.map(String.init) ?? error
            return AnyView(OctetErrorState(title: "Couldn't load \(section.title)", reason: reason,
                                           actionTitle: "Try Again", action: { retry(section) },
                                           details: error, fills: false)
                .padding(.top, 56))
        }
        if total == 0 {
            let (title, message): (String, String) = switch section {
            case .mcp: ("No MCP servers yet", "Add a server once and Octet installs it into each agent in its own syntax.")
            case .plugins: ("No plugins available", "Add a plugin marketplace to browse what it offers.")
            case .skills: ("No skills yet", "Skills in your library are linked into every agent you pick.")
            case .prompts: ("No prompts yet", "Prompts in your library become slash commands in every agent you pick.")
            }
            return AnyView(MarketplaceEmptyState(symbol: section.symbol, title: title, message: message,
                                                 actionTitle: addTitle, action: add))
        }
        if visible == 0, !store.query.trimmingCharacters(in: .whitespaces).isEmpty {
            return AnyView(MarketplaceEmptyState(
                symbol: "magnifyingglass", title: "No matches",
                message: "Nothing in \(section.title) matches \u{201C}\(store.query.trimmingCharacters(in: .whitespaces))\u{201D}. Search looks at names and descriptions.",
                actionTitle: "Clear Search"
            ) { store.query = "" })
        }
        return nil
    }

    // MARK: Editors

    @ViewBuilder private var editorOverlay: some View {
        if let editor {
            ZStack {
                Theme.scrim
                    .contentShape(Rectangle())
                    .onTapGesture { self.editor = nil }
                    .accessibilityHidden(true)
                Group {
                    switch editor {
                    case .library(let draft):
                        LibraryEditor(store: store, draft: draft) { self.editor = nil }
                    case .server:
                        ServerEditor(store: store) { self.editor = nil }
                    }
                }
                .frame(width: 560)
                .octetGlass(cornerRadius: 14)
                .padding(40)
            }
            .transition(.opacity)
            .id(editor.id)
        }
    }
}

/// Which editor is over the page.
enum MarketplaceEditorKind: Identifiable {
    case library(LibraryDraft)
    case server

    var id: String {
        switch self {
        case .library(let draft): draft.id.uuidString
        case .server: "server"
        }
    }
}

/// A skill or prompt an agent has that the library doesn't.
struct UnmanagedItem: Identifiable {
    let host: AgentHost
    let slug: String
    var id: String { "\(host.id):\(slug)" }
}

/// The Marketplace window's own chrome, which the page in the main window
/// doesn't want: its size, title bar and theme, and its own toasts and
/// confirmations.
private struct MarketplaceChrome: ViewModifier {
    let embedded: Bool
    @ObservedObject private var settings = SettingsStore.shared

    func body(content: Content) -> some View {
        if embedded {
            content
        } else {
            content
                .frame(minWidth: 820, minHeight: 540)
                .overlay(alignment: .bottomTrailing) { ToastStack(center: ToastCenter.shared) }
                .overlay { ConfirmDialog(center: ConfirmCenter.shared) }
                .ignoresSafeArea()
                .background(DarkTransparentTitleBar())
                .background(ThemedWindow(themeName: settings.themeKey))
                .preferredColorScheme(Theme.colorScheme)
        }
    }
}
