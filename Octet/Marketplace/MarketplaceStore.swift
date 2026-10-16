import AppKit
import Foundation

/// Backs the Marketplace: browses and installs MCP servers, plugins, skills
/// and prompts across every agent host, then reloads running agents in place
/// so changes apply without losing the conversation.
@MainActor
final class MarketplaceStore: ObservableObject {
    enum Section: String, CaseIterable, Identifiable {
        case mcp, plugins, skills, prompts

        var id: String { rawValue }
        var title: String {
            switch self {
            case .mcp: "MCP Servers"
            case .plugins: "Plugins"
            case .skills: "Skills"
            case .prompts: "Prompts"
            }
        }
        var symbol: String {
            switch self {
            case .mcp: "point.3.connected.trianglepath.dotted"
            case .plugins: "puzzlepiece.extension"
            case .skills: "graduationcap"
            case .prompts: "text.bubble"
            }
        }
    }

    /// A query belongs to the list it was typed over, so switching clears it.
    @Published var section: Section = .mcp {
        didSet { if section != oldValue { query = "" } }
    }
    @Published var query = ""
    /// One agent's view of every section: what it has, and what it could
    /// add. nil shows every agent.
    @Published var agentFilter: String?
    /// How the plugins on offer are ordered; the rest are by name.
    @Published var sort: SortOrder = .popular

    enum SortOrder: String, CaseIterable, Identifiable {
        case popular, name
        var id: String { rawValue }
        var title: String {
            switch self {
            case .popular: "Most installed"
            case .name: "Name"
            }
        }
    }
    /// Plugins for agents and for the terminal share one list.
    @Published var pluginFilter: PluginFilter = .all

    enum PluginFilter: String, CaseIterable, Identifiable {
        case all, agents, terminal
        var id: String { rawValue }
        var title: String {
            switch self {
            case .all: "All"
            case .agents: "Agents"
            case .terminal: "Terminal"
            }
        }
    }
    @Published private(set) var hosts: [AgentHost] = []
    @Published private(set) var plugins: [MarketplaceEntry] = [] {
        didSet {
            pluginGroupsCache = nil
            installedPluginCount = plugins.filter(\.isInstalled).count
        }
    }
    /// Counted once per load rather than on every redraw of 10,000 rows.
    @Published private(set) var installedPluginCount = 0
    @Published private(set) var servers: [MarketplaceEntry] = []
    @Published private(set) var skills: [AgentLibrary.Item] = []
    @Published private(set) var prompts: [AgentLibrary.Item] = []
    /// Plugin marketplaces each host has configured, by host id.
    @Published private(set) var marketplaces: [String: [MarketplaceSource]] = [:]

    struct MarketplaceSource: Hashable {
        let name: String
        let source: String
    }
    @Published private(set) var loading: Set<Section> = []
    /// Sections that have finished at least one load, so an empty list
    /// means empty rather than not fetched yet.
    @Published private(set) var loaded: Set<Section> = []
    /// Why the last load of a section failed, from CLI exit codes.
    @Published private(set) var loadErrors: [Section: String] = [:]
    /// `busyKey(entry, host)` for every install or removal still running.
    @Published private(set) var busy: Set<String> = []
    /// Set after a change that running agents only pick up on restart.
    @Published private(set) var pendingReload = false
    /// Agents are restarting after Reload Agents.
    @Published private(set) var reloading = false

    private let recovery: AgentRecoveryController
    private unowned let session: SessionStore
    private var catalogLoadedAt = Date.distantPast
    private static let catalogURL = EngineSession.supportDirectory.appendingPathComponent("plugin-catalog.json")
    /// The plugin catalogs take tens of seconds to fetch, so they're cached.
    static let catalogLifetime: TimeInterval = 6 * 3600
    /// Rows a list shows before "Show more"; each click adds as many again.
    static let pageSize = 100
    private var pluginGroupsCache: (key: String, value: Groups<MarketplaceEntry>)?

    init(session: SessionStore) {
        self.session = session
        recovery = session.recovery
        hosts = AgentHosts.installed()
    }

    /// The agent a prompt would run in: the focused pane's, else the only one.
    var promptTarget: EngineAgent? {
        let agents = session.snapshot.agents
        return agents.first { $0.paneId == session.keyPaneId }
            ?? agents.first { $0.tabId == session.keyTabId }
            ?? (agents.count == 1 ? agents.first : nil)
    }

    /// Submits a library prompt to a running agent, whichever agent it is.
    func runPrompt(_ item: AgentLibrary.Item) {
        guard let agent = promptTarget else {
            ToastCenter.shared.info("No agent to run this in", detail: "Focus a tab running an agent first")
            return
        }
        let text = text(of: item)
        let body = AgentLibrary.promptBody(text)
        guard !body.isEmpty else {
            ToastCenter.shared.fail(nil, "\(item.name) is empty")
            return
        }
        let name = AgentBrand.forAgent(agent.agent)?.displayName ?? "the agent"
        let toast = ToastCenter.shared.progress("Sending \(item.name) to \(name)…")
        let client = session.client
        DispatchQueue.global(qos: .userInitiated).async {
            let outcome = Result { try client.call("agent.prompt", ["target": agent.paneId, "text": body]) }
            DispatchQueue.main.async {
                switch outcome {
                case .success:
                    ToastCenter.shared.succeed(toast, "Sent \(item.name) to \(name)")
                case .failure(let error):
                    ToastCenter.shared.fail(toast, "Couldn't send \(item.name)", detail: String(describing: error))
                }
            }
        }
    }

    /// Copies `.md` files from a folder into the library (a prompt pack).
    func importPrompts(from directory: URL, installIn hosts: [AgentHost]) {
        let names = (try? FileManager.default.contentsOfDirectory(atPath: directory.path)) ?? []
        let files = names.filter { $0.hasSuffix(".md") && $0.lowercased() != "readme.md" }
        guard !files.isEmpty else {
            ToastCenter.shared.info("No prompts found", detail: "\(directory.lastPathComponent) has no .md files")
            return
        }
        var added = 0
        var failed: [String] = []
        for file in files {
            let slug = String(file.dropLast(3))
            guard let text = try? String(contentsOfFile: directory.appendingPathComponent(file).path, encoding: .utf8),
                  saveLibraryItem(kind: .prompt, slug: slug, text: text, installIn: hosts, quiet: true) else {
                failed.append(file)
                continue
            }
            added += 1
        }
        loadLibrary()
        if failed.isEmpty {
            ToastCenter.shared.info("Imported \(added) prompt\(added == 1 ? "" : "s")",
                                    detail: "From \(directory.lastPathComponent)")
        } else {
            ToastCenter.shared.fail(nil, "Imported \(added) of \(files.count) prompts",
                                    detail: "Couldn't import \(failed.prefix(3).joined(separator: ", "))\(failed.count > 3 ? "…" : "")")
        }
    }

    // MARK: - Loading

    func refreshAll(force: Bool = false) {
        hosts = AgentHosts.installed()
        loadLibrary()
        loadServers()
        loadPlugins(force: force)
        OctetPluginHost.shared.reload()
        OctetPluginHost.shared.loadRegistry(force: force)
    }

    func loadLibrary() {
        skills = AgentLibrary.items(.skill, hosts: hosts)
        prompts = AgentLibrary.items(.prompt, hosts: hosts)
        loaded.formUnion([.skills, .prompts])
    }

    func loadServers() {
        guard !loading.contains(.mcp) else { return }
        loading.insert(.mcp)
        let hosts = self.hosts.filter(\.supportsMCP)
        run(hosts.map { "\($0.cli) mcp list" }, timeout: 120) { [weak self] results in
            guard let self else { return }
            // A host whose CLI failed would otherwise read as having no servers.
            let succeeded = zip(hosts, results).filter { $0.1.exitCode == 0 }
            let lists = succeeded.map { host, result in
                host.id == "codex" ? MarketplaceCatalog.codexMCP(result.output) : MarketplaceCatalog.claudeMCP(result.output)
            }
            self.servers = MarketplaceCatalog.merge(lists).sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
            self.loadErrors[.mcp] = Self.failureSummary(hosts: hosts, results: results)
            self.loaded.insert(.mcp)
            self.loading.remove(.mcp)
        }
    }

    func loadPlugins(force: Bool) {
        guard !loading.contains(.plugins) else { return }
        if !force, plugins.isEmpty, let cached = Self.loadCachedCatalog() {
            plugins = cached.entries
            catalogLoadedAt = cached.date
            loaded.insert(.plugins)
        }
        guard force || Date().timeIntervalSince(catalogLoadedAt) > Self.catalogLifetime else { return }
        loading.insert(.plugins)
        let hosts = self.hosts.filter(\.supportsPlugins)
        // --available pulls every configured marketplace, which is slow.
        run(hosts.map { "\($0.cli) plugin list --json --available" }, timeout: 300) { [weak self] results in
            guard let self else { return }
            let succeeded = zip(hosts, results).filter { $0.1.exitCode == 0 }
            let lists = succeeded.map { host, result in
                MarketplaceCatalog.plugins(json: Data(Self.jsonBody(result.output).utf8), hostId: host.id)
            }
            let merged = MarketplaceCatalog.merge(lists)
            let failure = Self.failureSummary(hosts: hosts, results: results)
            if failure == nil {
                self.plugins = merged
                self.catalogLoadedAt = Date()
                if !merged.isEmpty {
                    Self.cacheCatalog(outputs: zip(hosts.map(\.id), results.map(\.output)).map { ($0, $1) })
                }
            } else if self.plugins.isEmpty {
                // Partial results beat nothing; the error says what's missing.
                self.plugins = merged
            }
            self.loadErrors[.plugins] = failure
            self.loaded.insert(.plugins)
            self.loading.remove(.plugins)
        }
        run(hosts.map { "\($0.cli) plugin marketplace list" }, timeout: 120) { [weak self] results in
            guard let self else { return }
            var result: [String: [MarketplaceSource]] = [:]
            for (host, output) in zip(hosts, results) where output.exitCode == 0 {
                result[host.id] = MarketplaceCatalog.marketplaces(output.output).map { MarketplaceSource(name: $0.name, source: $0.source) }
            }
            self.marketplaces = result
        }
    }

    // MARK: - Actions

    func installPlugin(_ entry: MarketplaceEntry, into hosts: [AgentHost]) {
        let hosts = idle(entry.id, hosts)
        perform(
            hosts.map { "\($0.cli) plugin install \(PluginCLI.quote(entry.identifier))" },
            busy: hosts.map { Self.busyKey(entry.id, $0) },
            progress: "Installing \(entry.name)…",
            success: "Installed \(entry.name)",
            failure: "Couldn't install \(entry.name)",
            reloadAgents: true
        ) { [weak self] _ in self?.loadPlugins(force: true) }
    }

    func uninstallPlugin(_ entry: MarketplaceEntry, from hosts: [AgentHost]) {
        let hosts = idle(entry.id, hosts)
        perform(
            hosts.map { "\($0.cli) plugin uninstall \(PluginCLI.quote(entry.identifier))" },
            busy: hosts.map { Self.busyKey(entry.id, $0) },
            progress: "Removing \(entry.name)…",
            success: "Removed \(entry.name)",
            failure: "Couldn't remove \(entry.name)",
            reloadAgents: true
        ) { [weak self] _ in self?.loadPlugins(force: true) }
    }

    func setPluginEnabled(_ entry: MarketplaceEntry, in host: AgentHost, enabled: Bool) {
        guard !isBusy(entry, host) else { return }
        let verb = enabled ? "enable" : "disable"
        perform(
            ["\(host.cli) plugin \(verb) \(PluginCLI.quote(entry.identifier))"],
            busy: [Self.busyKey(entry.id, host)],
            progress: "\(enabled ? "Enabling" : "Disabling") \(entry.name)…",
            success: "\(enabled ? "Enabled" : "Disabled") \(entry.name)",
            failure: "Couldn't \(verb) \(entry.name)",
            reloadAgents: true
        ) { [weak self] _ in self?.loadPlugins(force: true) }
    }

    func addMarketplace(_ source: String, to hosts: [AgentHost]) {
        perform(
            hosts.map { "\($0.cli) plugin marketplace add \(PluginCLI.quote(source))" },
            progress: "Adding marketplace \(source)…",
            success: "Added marketplace \(source)",
            failure: "Couldn't add \(source)",
            reloadAgents: false
        ) { [weak self] _ in self?.loadPlugins(force: true) }
    }

    /// Adds an MCP server from one definition, in each host's own syntax.
    /// `completion` gets nil on success, else what went wrong.
    func addServer(name: String, command: String, into hosts: [AgentHost], completion: ((String?) -> Void)? = nil) {
        let entryId = "\(MarketplaceEntry.Kind.mcp.rawValue):\(name)"
        let hosts = idle(entryId, hosts.filter(\.supportsMCP))
        guard !hosts.isEmpty else {
            completion?("No agent to add it to")
            return
        }
        // Copying a server from Claude brings its "(HTTP)" label along.
        let target = MarketplaceCatalog.serverTarget(command)
        let trimmed = target.value
        let isURL = target.isURL
        guard !trimmed.isEmpty else {
            completion?("No command or URL to run")
            return
        }
        let commands = hosts.map { host -> String in
            switch host.id {
            case "codex":
                return isURL
                    ? "\(host.cli) mcp add \(PluginCLI.quote(name)) --url \(PluginCLI.quote(trimmed))"
                    : "\(host.cli) mcp add \(PluginCLI.quote(name)) -- \(trimmed)"
            default:
                return isURL
                    ? "\(host.cli) mcp add --transport \(target.transport) \(PluginCLI.quote(name)) \(PluginCLI.quote(trimmed))"
                    : "\(host.cli) mcp add \(PluginCLI.quote(name)) -- \(trimmed)"
            }
        }
        perform(commands, busy: hosts.map { Self.busyKey(entryId, $0) },
                progress: "Adding \(name)…", success: "Added MCP server \(name)",
                failure: "Couldn't add \(name)", reloadAgents: true) { [weak self] error in
            self?.loadServers()
            completion?(error)
        }
    }

    func removeServer(_ entry: MarketplaceEntry, from hosts: [AgentHost]) {
        let hosts = idle(entry.id, hosts.filter(\.supportsMCP))
        perform(
            hosts.map { "\($0.cli) mcp remove \(PluginCLI.quote(entry.identifier))" },
            busy: hosts.map { Self.busyKey(entry.id, $0) },
            progress: "Removing \(entry.name)…",
            success: "Removed MCP server \(entry.name)",
            failure: "Couldn't remove \(entry.name)",
            reloadAgents: true
        ) { [weak self] _ in self?.loadServers() }
    }

    /// Adds an entry to hosts it isn't in yet. For an MCP server this copies
    /// the definition another agent already has.
    func add(_ entry: MarketplaceEntry, to hosts: [AgentHost]) {
        switch entry.kind {
        case .plugin: installPlugin(entry, into: hosts)
        case .mcp: addServer(name: entry.identifier, command: entry.detail, into: hosts)
        }
    }

    func remove(_ entry: MarketplaceEntry, from hosts: [AgentHost]) {
        switch entry.kind {
        case .plugin: uninstallPlugin(entry, from: hosts)
        case .mcp: removeServer(entry, from: hosts)
        }
    }

    // MARK: Busy state

    static func busyKey(_ entryId: String, _ host: AgentHost) -> String { "\(entryId)|\(host.id)" }

    func isBusy(_ entry: MarketplaceEntry, _ host: AgentHost) -> Bool {
        busy.contains(Self.busyKey(entry.id, host))
    }

    func isBusy(_ entry: MarketplaceEntry) -> Bool {
        hosts.contains { isBusy(entry, $0) }
    }

    /// Drops hosts that already have a change running for this entry, so a
    /// second click can't submit the same command twice.
    private func idle(_ entryId: String, _ hosts: [AgentHost]) -> [AgentHost] {
        hosts.filter { !busy.contains(Self.busyKey(entryId, $0)) }
    }

    // MARK: Library (skills and prompts)

    func setLibraryInstalled(_ item: AgentLibrary.Item, host: AgentHost, installed: Bool) {
        do {
            if installed {
                try AgentLibrary.install(item, into: host)
            } else {
                try AgentLibrary.uninstall(item, from: host)
            }
            loadLibrary()
            markPendingReload(item.kind == .skill)
            ToastCenter.shared.info(
                "\(installed ? "Added" : "Removed") \(item.name) \(installed ? "to" : "from") \(host.displayName)"
            )
        } catch {
            ToastCenter.shared.fail(nil, "Couldn't update \(item.name)", detail: String(describing: error))
        }
    }

    @discardableResult
    func saveLibraryItem(kind: AgentLibrary.Kind, slug: String, text: String, installIn hosts: [AgentHost], quiet: Bool = false) -> Bool {
        do {
            let item = try AgentLibrary.save(kind: kind, slug: slug, text: text, hosts: self.hosts)
            for host in hosts { try AgentLibrary.install(item, into: host) }
            loadLibrary()
            markPendingReload(kind == .skill)
            if !quiet {
                ToastCenter.shared.info("Saved \(item.name)", detail: hosts.isEmpty ? nil : "Installed in \(hosts.map(\.displayName).joined(separator: ", "))")
            }
            return true
        } catch {
            ToastCenter.shared.fail(nil, "Couldn't save \(slug)", detail: String(describing: error))
            return false
        }
    }

    func deleteLibraryItem(_ item: AgentLibrary.Item) {
        do {
            try AgentLibrary.delete(item, hosts: hosts)
            loadLibrary()
            markPendingReload(item.kind == .skill)
            ToastCenter.shared.info("Deleted \(item.name)")
        } catch {
            ToastCenter.shared.fail(nil, "Couldn't delete \(item.name)", detail: String(describing: error))
        }
    }

    /// Skills and prompts a host already had, which the library can take over.
    func unmanaged(_ kind: AgentLibrary.Kind) -> [(host: AgentHost, slugs: [String])] {
        hosts.compactMap { host in
            let slugs = AgentLibrary.unmanaged(kind, in: host)
            return slugs.isEmpty ? nil : (host, slugs)
        }
    }

    func adopt(kind: AgentLibrary.Kind, slug: String, from host: AgentHost) {
        do {
            try AgentLibrary.adopt(kind: kind, slug: slug, from: host, hosts: hosts)
            loadLibrary()
            ToastCenter.shared.info("Added \(slug) to your library", detail: "Now shareable with your other agents")
        } catch {
            ToastCenter.shared.fail(nil, "Couldn't import \(slug)", detail: String(describing: error))
        }
    }

    func text(of item: AgentLibrary.Item) -> String {
        (try? String(contentsOfFile: item.contentPath, encoding: .utf8)) ?? ""
    }

    // MARK: - Hot swap

    /// Restarts running agents so new MCP servers, plugins, or skills load,
    /// resuming each conversation where it left off.
    func reloadAgents(confirm: Bool = true) {
        let reloadable = recovery.reloadableAgents()
        let blocked = recovery.unreloadableAgents()
        guard !reloadable.isEmpty else {
            let detail = blocked.isEmpty
                ? "Nothing is running that Octet can restart"
                : blocked.map { "\(AgentBrand.forAgent($0.agent.agent)?.displayName ?? "agent"): \($0.reason)" }.joined(separator: "\n")
            ToastCenter.shared.info("No agents to reload", detail: detail)
            pendingReload = false
            return
        }
        guard confirm else {
            startReload(reloadable)
            return
        }
        let working = reloadable.filter { $0.agent.agentStatus == .working }.count
        var lines = ["Each one restarts with --resume, so the conversation is kept."]
        if working > 0 { lines.append("\(working) \(working == 1 ? "is" : "are") working right now and will be interrupted.") }
        if !blocked.isEmpty { lines.append("Skipping \(blocked.count): \(blocked.map(\.reason).joined(separator: ", ")).") }
        ConfirmCenter.shared.ask(
            title: "Reload \(reloadable.count) running agent\(reloadable.count == 1 ? "" : "s")?",
            message: lines.joined(separator: " "),
            items: reloadable.map { record in
                let name = AgentBrand.forAgent(record.agent.agent)?.displayName ?? "agent"
                return record.record.tabLabel.isEmpty ? name : "\(name) · \(record.record.tabLabel)"
            },
            confirmTitle: "Reload"
        ) { [weak self] _ in
            self?.startReload(reloadable)
        }
    }

    private func startReload(_ agents: [(agent: EngineAgent, record: AgentSessionRecord)]) {
        pendingReload = false
        reloading = true
        recovery.reload(agents) { [weak self] in self?.reloading = false }
    }

    private func markPendingReload(_ affectsAgents: Bool = true) {
        if affectsAgents, !recovery.reloadableAgents().isEmpty { pendingReload = true }
    }

    // MARK: - Filtering

    /// A section's rows split into what's installed (in the filtered agent,
    /// or any) and what isn't yet.
    struct Groups<T> {
        var installed: [T] = []
        var available: [T] = []
        var isEmpty: Bool { installed.isEmpty && available.isEmpty }
        var count: Int { installed.count + available.count }
    }

    /// The agents a section's items go into: the filtered one when it can
    /// take them, else every capable one.
    func scopeHosts(for section: Section) -> [AgentHost] {
        let capable = capableHosts(for: section)
        guard let agentFilter else { return capable }
        return capable.filter { $0.id == agentFilter }
    }

    func capableHosts(for section: Section) -> [AgentHost] {
        hosts.filter { host in
            switch section {
            case .mcp: host.supportsMCP
            case .plugins: host.supportsPlugins
            case .skills, .prompts: true
            }
        }
    }

    /// Whether the filtered agent (or any) has an item.
    private func isInstalled(_ installedIn: Set<String>) -> Bool {
        agentFilter.map(installedIn.contains) ?? !installedIn.isEmpty
    }

    private func split<T>(_ items: [T], installedIn: (T) -> Set<String>) -> Groups<T> {
        var groups = Groups<T>()
        for item in items {
            if isInstalled(installedIn(item)) { groups.installed.append(item) } else { groups.available.append(item) }
        }
        return groups
    }

    func serverGroups() -> Groups<MarketplaceEntry> {
        let found = MarketplaceCatalog.search(servers, query: query, names: { [$0.name] }, texts: { [$0.detail] })
        return split(found, installedIn: \.installedIn)
    }

    /// Searched, split and sorted once per change of list, query, order or
    /// agent: the catalog runs to thousands of plugins.
    func pluginGroups() -> Groups<MarketplaceEntry> {
        let key = "\(query)|\(sort.rawValue)|\(agentFilter ?? "")"
        if let cache = pluginGroupsCache, cache.key == key { return cache.value }
        let ordered: [MarketplaceEntry] = switch sort {
        case .popular: MarketplaceCatalog.sorted(plugins)
        case .name: plugins.sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
        }
        let found = MarketplaceCatalog.search(ordered, query: query,
                                              names: { [$0.name, $0.identifier] }, texts: { [$0.summary, $0.marketplace] })
        let groups = split(found, installedIn: \.installedIn)
        pluginGroupsCache = (key, groups)
        return groups
    }

    /// One of Octet's own plugins: built in, installed, or in the registry.
    struct TerminalPlugin: Identifiable {
        let id: String
        let name: String
        let summary: String
        let author: String
        let version: String
        let keywords: [String]
        /// On disk, when it's built in or installed.
        let installed: OctetPlugin?
        /// In the registry, when it's listed there.
        let entry: PluginRegistry.Entry?
    }

    /// Octet's plugins that match the search: built-in and installed ones,
    /// then what the registry offers. They belong to no agent, so an agent
    /// filter leaves them out.
    func terminalPluginGroups() -> Groups<TerminalPlugin> {
        guard agentFilter == nil else { return Groups() }
        let host = OctetPluginHost.shared
        let installedIds = Set(host.plugins.map(\.id))
        let local = host.plugins.map { plugin in
            TerminalPlugin(id: plugin.id, name: plugin.manifest.name, summary: plugin.manifest.description ?? "",
                           author: plugin.isBundled ? "Octet" : plugin.manifest.author ?? "", version: plugin.manifest.version,
                           keywords: [], installed: plugin, entry: host.registry.first { $0.id == plugin.id })
        }
        .sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
        let available = host.registry.filter { !installedIds.contains($0.id) }.map { entry in
            TerminalPlugin(id: entry.id, name: entry.name, summary: entry.description, author: entry.author,
                           version: entry.version, keywords: entry.keywords, installed: nil, entry: entry)
        }
        .sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
        func search(_ items: [TerminalPlugin]) -> [TerminalPlugin] {
            MarketplaceCatalog.search(items, query: query, names: { [$0.name, $0.id] }, texts: { [$0.summary] + $0.keywords })
        }
        return Groups(installed: search(local), available: search(available))
    }

    func libraryGroups(_ kind: AgentLibrary.Kind) -> Groups<AgentLibrary.Item> {
        let found = MarketplaceCatalog.search(kind == .skill ? skills : prompts, query: query,
                                              names: { [$0.name, $0.slug] }, texts: { [$0.summary] })
        return split(found, installedIn: \.installedIn)
    }

    /// How many of a section's items an agent has.
    func installedCount(_ section: Section, in host: AgentHost) -> Int {
        switch section {
        case .mcp: servers.filter { $0.installedIn.contains(host.id) }.count
        case .plugins: plugins.filter { $0.installedIn.contains(host.id) }.count
        case .skills: skills.filter { $0.installedIn.contains(host.id) }.count
        case .prompts: prompts.filter { $0.installedIn.contains(host.id) }.count
        }
    }

    // MARK: - Running CLIs

    /// Runs commands in parallel and delivers their results in order.
    private func run(_ commands: [String], timeout: TimeInterval, completion: @escaping ([PluginCLI.Result]) -> Void) {
        guard !commands.isEmpty else {
            completion([])
            return
        }
        var results = [PluginCLI.Result?](repeating: nil, count: commands.count)
        var remaining = commands.count
        for (index, command) in commands.enumerated() {
            PluginCLI.runShell(command, timeout: timeout) { result in
                results[index] = result
                remaining -= 1
                if remaining == 0 {
                    completion(results.map { $0 ?? PluginCLI.Result(exitCode: -1, output: "No output") })
                }
            }
        }
    }

    /// One line per host whose command failed, or nil when all succeeded.
    private static func failureSummary(hosts: [AgentHost], results: [PluginCLI.Result]) -> String? {
        let lines = zip(hosts, results).compactMap { host, result -> String? in
            guard result.exitCode != 0 else { return nil }
            let tail = PluginCLI.lastLines(result.output, count: 2)
            return "\(host.displayName): \(tail.isEmpty ? "exited with status \(result.exitCode)" : tail)"
        }
        return lines.isEmpty ? nil : lines.joined(separator: "\n")
    }

    /// Runs change commands, marking `busy` keys for their duration, and
    /// hands `then` nil on success or the failure detail.
    private func perform(
        _ commands: [String],
        busy keys: [String] = [],
        progress: String,
        success: String,
        failure: String,
        reloadAgents: Bool,
        then: @escaping (String?) -> Void
    ) {
        guard !commands.isEmpty else { return }
        busy.formUnion(keys)
        let toast = ToastCenter.shared.progress(progress)
        var failures: [String] = []
        var remaining = commands.count
        for command in commands {
            PluginCLI.runShell(command, timeout: 600) { [weak self] result in
                if result.exitCode != 0 { failures.append(PluginCLI.lastLines(result.output)) }
                remaining -= 1
                guard remaining == 0, let self else { return }
                self.busy.subtract(keys)
                let detail = failures.prefix(2).joined(separator: "\n")
                if failures.isEmpty {
                    ToastCenter.shared.succeed(toast, success)
                    if reloadAgents { self.markPendingReload() }
                } else {
                    ToastCenter.shared.fail(toast, failure, detail: detail)
                }
                then(failures.isEmpty ? nil : (detail.isEmpty ? failure : detail))
            }
        }
    }

    /// CLI output can carry banner lines before the JSON body.
    private static func jsonBody(_ output: String) -> String {
        guard let start = output.firstIndex(where: { $0 == "{" || $0 == "[" }) else { return output }
        return String(output[start...])
    }

    private static func cacheCatalog(outputs: [(String, String)]) {
        let payload = outputs.map { ["host": $0.0, "output": jsonBody($0.1)] }
        guard let data = try? JSONSerialization.data(withJSONObject: ["fetchedAt": Date().timeIntervalSince1970, "hosts": payload]) else { return }
        try? FileManager.default.createDirectory(at: catalogURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        try? data.write(to: catalogURL, options: .atomic)
    }

    private static func loadCachedCatalog() -> (entries: [MarketplaceEntry], date: Date)? {
        guard let data = try? Data(contentsOf: catalogURL),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let fetchedAt = object["fetchedAt"] as? TimeInterval,
              let hosts = object["hosts"] as? [[String: String]] else { return nil }
        let lists = hosts.map { entry in
            MarketplaceCatalog.plugins(json: Data((entry["output"] ?? "").utf8), hostId: entry["host"] ?? "")
        }
        return (MarketplaceCatalog.merge(lists), Date(timeIntervalSince1970: fetchedAt))
    }
}
