import SwiftUI

/// The footer under the terminal, after T3 Code's: quiet, dense items about
/// the focused pane in the order and selection set in Settings › Status Bar.
/// Nothing is boxed; colour is kept for what it means (a failing check, a
/// running build, a passing one), so the eye goes to it and nowhere else.
/// Items that have a plane open it, the way T3 Code's footer leads into its
/// panels. Over SSH only items about the other machine (or about nothing
/// local) show.
struct StatusBar: View {
    @ObservedObject var model: StatusBarModel
    @ObservedObject var store: SessionStore
    /// The window's panel, for the planes items open.
    @ObservedObject var ui: UIState
    let ssh: SSHTarget?
    let agent: EngineAgent?
    var openOnOctetUI: (EngineAgent) -> Void = { _ in }
    @ObservedObject private var plugins = OctetPluginHost.shared
    @ObservedObject private var motion = MotionPreferences.shared
    /// Redraws the account item when accounts change.
    @ObservedObject private var settings = SettingsStore.shared
    /// What serves each port, for the ports item's logo.
    @ObservedObject private var ports = PortsWatcher.shared
    @Environment(\.openURL) private var openURL
    @State private var ciShown = false
    /// The plugin item whose setup popover is open, by descriptor id.
    @State private var setupShown: String?
    /// Where each item sits in the bar as scrolled, and the bar's width,
    /// for the edge fades and the overflow menu.
    @State private var spans: [String: StatusBarOverflow.Span] = [:]
    @State private var barWidth: CGFloat = 0
    @State private var overflowShown = false

    static let height: CGFloat = 30

    /// Whether any item would draw, so an empty bar takes no room.
    @MainActor
    static func hasContent(model: StatusBarModel, ssh: SSHTarget?, agent: EngineAgent?) -> Bool {
        let host = OctetPluginHost.shared
        let descriptors = Dictionary(host.statusDescriptors.map { ($0.id, $0) }) { first, _ in first }
        return host.statusBarOrder.contains { id in
            descriptors[id].map { draws($0, model: model, ssh: ssh, agent: agent) } ?? false
        }
    }

    /// "Claude · Work", for each agent whose account here isn't the default.
    static func accountLabel(for directory: String?) -> String {
        guard let directory else { return "" }
        let accounts = AccountProfiles.inForce(for: directory)
            .map { "\(AgentBrand.forAgent($0.agent)?.displayName ?? $0.agent) · \($0.name)" }
        let credentials = CredentialProfiles.inForce(for: directory).map(\.name)
        return (accounts + credentials).joined(separator: ", ")
    }

    /// Whether an item has something to show; `item(for:)` draws exactly these.
    static func draws(_ descriptor: StatusItemDescriptor, model: StatusBarModel, ssh: SSHTarget?, agent: EngineAgent?) -> Bool {
        switch descriptor.scope {
        case .local: guard ssh == nil else { return false }
        case .remote: guard ssh != nil else { return false }
        case .any: break
        }
        switch descriptor.id {
        case "builtin.ssh": return ssh != nil
        case "builtin.agent": return agent != nil
        case "builtin.account": return !Self.accountLabel(for: model.directory).isEmpty
        case "builtin.lastCommand": return model.lastCommand != nil
        case "builtin.remoteControl": return model.remoteControlOn
        case "builtin.runtime": return model.runtime != nil
        case "builtin.directory": return model.directory != nil
        case "builtin.branch": return model.repo?.branch != nil
        case "builtin.worktree": return model.repo?.linkedWorktree == true
        case "builtin.gitState": return model.repo.map { !$0.operation.isEmpty } ?? false
        case "builtin.changes": return model.repo?.changes.map { !$0.isEmpty } ?? false
        case "builtin.pullRequest": return model.repo?.pullRequest != nil
        case "builtin.ci": return model.repo?.ci != nil
        default: return model.pluginOutputs[descriptor.id] != nil
        }
    }

    var body: some View {
        let descriptors = Dictionary(plugins.statusDescriptors.map { ($0.id, $0) }) { first, _ in first }
        let shown = plugins.statusBarOrder.filter { id in
            descriptors[id].map { Self.draws($0, model: model, ssh: ssh, agent: agent) } ?? false
        }
        let dividers = StatusBarItems.dividers(before: shown)
        let edges = StatusBarOverflow.edges(of: shown.compactMap { spans[$0] }, width: barWidth)
        HStack(spacing: 0) {
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 2) {
                    ForEach(Array(shown.enumerated()), id: \.element) { index, id in
                        if dividers.contains(index) { StatusBarDivider() }
                        if let descriptor = descriptors[id] {
                            item(for: descriptor).background(StatusItemSpanReader(id: id))
                        }
                    }
                }
                .padding(.horizontal, Theme.Space.sm)
                .frame(height: Self.height)
            }
            .coordinateSpace(name: StatusItemSpanReader.space)
            .background(GeometryReader { proxy in Color.clear.preference(key: StatusBarWidthKey.self, value: proxy.size.width) })
            .onPreferenceChange(StatusItemSpansKey.self) { spans = $0 }
            .onPreferenceChange(StatusBarWidthKey.self) { barWidth = $0 }
            .mask(edgeFades(edges))
            if !edges.hidden.isEmpty {
                overflowButton(edges.hidden.compactMap { descriptors[$0] })
            }
            // Awake, memory, ports and hosts stay at the right, outside the
            // scrolling chips.
            FooterStatus(store: store)
                .layoutPriority(1)
                .padding(.trailing, Theme.Space.sm)
        }
        .animation(motion.animation(.connections, .spring(response: 0.4, dampingFraction: 0.7)), value: ssh)
        .animation(motion.animation(.connections, .spring(response: 0.4, dampingFraction: 0.7)), value: model.remoteControlOn)
        .frame(height: Self.height)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Theme.terminalBackground)
        .overlay(alignment: .top) { Rectangle().fill(Theme.divider).frame(height: 1) }
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Status bar")
    }

    /// Fades the bar out at an edge that has more items beyond it.
    private func edgeFades(_ edges: StatusBarOverflow.Edges) -> some View {
        HStack(spacing: 0) {
            LinearGradient(colors: [.clear, .black], startPoint: .leading, endPoint: .trailing)
                .frame(width: edges.leading ? Theme.Space.xl : 0)
            Rectangle()
            LinearGradient(colors: [.black, .clear], startPoint: .leading, endPoint: .trailing)
                .frame(width: edges.trailing ? Theme.Space.xl : 0)
        }
    }

    /// The items that don't fit, one click away instead of a sideways scroll.
    private func overflowButton(_ hidden: [StatusItemDescriptor]) -> some View {
        OctetIconButton(icon: "ellipsis", help: hidden.count == 1 ? "1 more item" : "\(hidden.count) more items",
                        active: overflowShown, compact: true) { overflowShown.toggle() }
            .padding(.trailing, Theme.Space.sm)
            .popover(isPresented: $overflowShown, arrowEdge: .top) {
                VStack(alignment: .leading, spacing: Theme.Space.xxs) {
                    ForEach(hidden, id: \.id) { descriptor in item(for: descriptor) }
                }
                .padding(Theme.Space.sm)
                .background(Theme.terminalBackground)
            }
    }

    /// Slides in from the leading edge as it arrives, for the connections
    /// (SSH, Remote Control) that change under someone without a click.
    private var arrival: AnyTransition {
        motion.animates(.connections)
            ? .asymmetric(insertion: .scale(scale: 0.6, anchor: .leading).combined(with: .opacity), removal: .opacity)
            : .identity
    }

    @ViewBuilder
    private func item(for descriptor: StatusItemDescriptor) -> some View {
        switch descriptor.id {
        case "builtin.ssh":
            if let ssh {
                StatusChip(tint: Theme.accent, help: "Connected over SSH to \(ssh.display)") {
                    StatusGlyph(symbol: "network")
                    Text(ssh.display).font(Theme.monoFont).lineLimit(1).truncationMode(.middle)
                }
                .accessibilityLabel("SSH to \(ssh.display)")
                .id(ssh.display)
                .transition(arrival)
            }
        case "builtin.agent":
            if let agent { agentItem(agent) }
        case "builtin.lastCommand":
            if let last = model.lastCommand { lastCommandItem(last) }
        case "builtin.account":
            let label = Self.accountLabel(for: model.directory)
            if !label.isEmpty {
                StatusChip(help: "Agents started here sign in with this account. Palette › Use Account for This Project changes it.") {
                    StatusGlyph(symbol: "person.crop.circle")
                    Text(label).lineLimit(1)
                }
            }
        case "builtin.remoteControl":
            if model.remoteControlOn {
                // Keyed like the SSH item, so it sweeps again each time it's shown.
                remoteControlItem(model.remoteControlURL)
                    .id(model.remoteControlURL?.absoluteString ?? "remote")
                    .transition(arrival)
            }
        case "builtin.runtime":
            if let runtime = model.runtime {
                StatusChip(help: "\(runtime.name)\(model.version.map { " \($0)" } ?? "")") {
                    if let badge = plugins.runtimeBadge(id: runtime.id) {
                        RuntimeIcon(badge: badge, size: 13)
                    }
                    Text(model.version ?? runtime.name)
                }
            }
        case "builtin.directory":
            if let directory = model.directory {
                Button { ui.showPlane(.files) } label: {
                    StatusChip(help: "\(directory)\nClick to show the project's files") {
                        OctetIcon("folder", size: 13)
                        Text(abbreviateHome(directory)).lineLimit(1).truncationMode(.head)
                    }
                }
                .buttonStyle(.plain)
                .modifier(LinkHover())
                .contextMenu {
                    Button("Show Files") { ui.showPlane(.files) }
                    Button("Copy Path") { copy(directory) }
                }
            }
        case "builtin.branch":
            if let repo = model.repo, let branch = repo.branch {
                BranchPickerChip(top: repo.root, branch: branch, detached: repo.detached, style: .statusBar,
                           changed: { model.refreshGitNow() })
                .contextMenu {
                    Button("Show Git") { ui.showPlane(.git) }
                    Button("Copy Branch Name") { copy(branch) }
                }
            }
        case "builtin.worktree":
            if let repo = model.repo, repo.linkedWorktree {
                // A click offers what's worth doing from a worktree.
                OctetMenuButton({ worktreeMenuItems(repo) }) {
                    StatusChip(help: "Worktree at \(repo.root)") {
                        OctetIcon("square.stack.3d.up", size: 13)
                        Text((repo.root as NSString).lastPathComponent).lineLimit(1)
                    }
                }
                .fixedSize()
                .contextMenu { worktreeActions(repo) }
            }
        case "builtin.gitState":
            if let operation = model.repo?.operation, !operation.isEmpty {
                Button { ui.showPlane(.git) } label: {
                    StatusChip(tone: operation.conflicts > 0 ? .danger : .warning,
                               help: "Finish or abort it before switching branches\nClick to show Git") {
                        StatusGlyph(symbol: "exclamationmark.triangle.fill")
                        Text(operation.label)
                    }
                }
                .buttonStyle(.plain)
                .modifier(LinkHover())
            }
        case "builtin.changes":
            if let changes = model.repo?.changes, !changes.isEmpty {
                Button { ui.showPlane(.diff) } label: {
                    StatusChip(help: "\(changes.files) changed \(changes.files == 1 ? "file" : "files") in the working tree, "
                               + "\(changes.added) lines added and \(changes.removed) removed\nClick to show the diff") {
                        OctetIcon("doc.diff", size: 13)
                        Text("\(changes.files)")
                        if changes.added > 0 || changes.removed > 0 {
                            DiffStatLabel(added: changes.added, removed: changes.removed, font: StatusBarStyle.font)
                        }
                    }
                }
                .buttonStyle(.plain)
                .modifier(LinkHover())
                .contextMenu {
                    Button("Show Diff") { ui.showPlane(.diff) }
                    Button("Review Changes") { WindowRegistry.shared.key?.toggleReview() }
                }
            }
        case "builtin.pullRequest":
            if let pullRequest = model.repo?.pullRequest {
                pullRequestItem(pullRequest)
            }
        case "builtin.ci":
            if let ci = model.repo?.ci {
                ciItem(ci)
            }
        case StatusBarItems.portsItemId:
            if let output = model.pluginOutputs[descriptor.id] {
                portsItem(descriptor, output)
            }
        default:
            if let output = model.pluginOutputs[descriptor.id] {
                pluginItem(descriptor, output)
            }
        }
    }

    /// How the pane's last command ended: a small green check and how long
    /// it took, or the exit code in red.
    private func lastCommandItem(_ last: PromptMark) -> some View {
        let succeeded = last.exitCode == 0
        let help = [last.command.map { "`\($0)`" }, last.exitCode.map { "exited \($0)" },
                    last.duration.map { "took " + PromptMarks.format($0) }].compactMap { $0 }.joined(separator: " · ")
        return StatusChip(tone: succeeded ? .normal : .danger, help: help) {
            if succeeded {
                OctetIcon("checkmark", size: 11).foregroundStyle(Theme.success)
            } else {
                OctetIcon("xmark", size: 11)
                Text("\(last.exitCode ?? -1)")
            }
            if let duration = last.duration {
                Text(PromptMarks.format(duration)).foregroundStyle(succeeded ? Theme.textTertiary : Theme.danger)
            }
        }
    }

    /// The branch's pull request: its state's glyph in GitHub's colours, its
    /// number, and its checks. A click shows it in the Pull Request plane.
    private func pullRequestItem(_ pullRequest: GitHubPullRequest) -> some View {
        let tone = PullRequestTone(state: pullRequest.state, isDraft: pullRequest.isDraft)
        return Button { ui.showPlane(.pullRequest, number: pullRequest.number) } label: {
            StatusChip(help: "\(pullRequest.title)\n\(pullRequest.statusText)\nClick to show the pull request") {
                OctetIcon(tone.icon, size: 13).foregroundStyle(tone.color)
                Text("#\(pullRequest.number)")
                checksGlyph(pullRequest)
            }
        }
        .buttonStyle(.plain)
        .modifier(LinkHover())
        .contextMenu {
            Button("Show Pull Request") { ui.showPlane(.pullRequest, number: pullRequest.number) }
            Button("Open on GitHub") { openURL(pullRequest.url) }
            Button("Copy Link") { copy(pullRequest.url.absoluteString) }
        }
    }

    /// CI for this commit at a glance: amber while it runs, a small green
    /// check once it passes, red when it fails. A click shows each workflow,
    /// and what to do about a failure.
    private func ciItem(_ ci: CIStatus) -> some View {
        let tone: StatusItemOutput.Tone = switch ci.overall {
        case .failed: .danger
        case .running: .warning
        case .cancelled: .muted
        case .passed: .normal
        }
        return Button { ciShown.toggle() } label: {
            StatusChip(tone: tone, help: ciHelp(ci)) {
                switch ci.overall {
                case .running:
                    LoadingLine(width: 10, color: StatusBarStyle.amber)
                    Text("CI \(ci.finished)/\(ci.runs.count)")
                case .passed:
                    OctetIcon("checkmark", size: 11).foregroundStyle(Theme.success)
                    Text("CI")
                case .failed:
                    OctetIcon("xmark", size: 11)
                    Text("CI \(ci.failed.count) failed")
                case .cancelled:
                    Text("CI cancelled")
                }
            }
            .opacity(ci.isHead ? 1 : 0.7)
        }
        .buttonStyle(.plain)
        .modifier(LinkHover())
        .popover(isPresented: $ciShown, arrowEdge: .top) {
            CIPopover(status: ci, branch: model.repo?.branch, hasAgent: agent.map { !$0.isSubagentViewer } ?? false,
                      rerun: { model.rerunFailed(ci) },
                      askAgent: {
                          ciShown = false
                          StatusBarModel.askAgentToFix(ci, branch: model.repo?.branch, pane: agent?.paneId)
                      },
                      refresh: { model.refreshCINow() })
        }
    }

    private func ciHelp(_ ci: CIStatus) -> String {
        let what: String = switch ci.overall {
        case .running: "CI running: \(ci.finished) of \(ci.runs.count) workflows done"
        case .passed: "CI passed"
        case .failed: "CI failed: " + ci.failed.map(\.workflow).joined(separator: ", ")
        case .cancelled: "CI cancelled"
        }
        return what + (ci.isHead ? "" : "\nFor \(ci.shortSha), the latest pushed commit; this one has no runs yet")
    }

    /// Remote Control is on for the agent in this pane: a light passes over
    /// the item; clicked, it opens the session on claude.ai.
    private func remoteControlItem(_ url: URL?) -> some View {
        Button { if let url { openURL(url) } } label: {
            StatusChip(tint: RemoteGlimmer.tint,
                       help: url.map { "Remote Control is on · \($0.absoluteString)" } ?? "Remote Control is on",
                       glimmer: true) {
                Circle().fill(RemoteGlimmer.tint).frame(width: 6, height: 6)
                Text("Remote")
            }
        }
        .buttonStyle(.plain)
        .modifier(LinkHover())
        .contextMenu {
            if let url {
                Button("Open in claude.ai") { openURL(url) }
                Button("Copy Link") { copy(url.absoluteString) }
            }
        }
    }

    private func agentItem(_ agent: EngineAgent) -> some View {
        let brand = AgentBrand.forAgent(agent.agent)
        let name = brand?.displayName ?? agent.agent ?? "Agent"
        let blocked = agent.agentStatus == .blocked
        let movable = AgentOffer.agentId(agent) != nil
        return Button { if movable { openOnOctetUI(agent) } } label: {
            StatusChip(tone: blocked ? .warning : .normal,
                       help: movable ? "\(name) · Click to open on Octet UI" : name) {
                if let brand { AgentLogo(brand: brand, size: 13) }
                Text(blocked ? "\(name) needs you" : [name, stateLabel(agent.agentStatus)].filter { !$0.isEmpty }.joined(separator: " "))
            }
        }
        .buttonStyle(.plain)
        .modifier(LinkHover(enabled: movable))
    }

    /// The PR's checks, as small as they can be and still read: a green
    /// check, a red cross, or an amber dot while they run.
    @ViewBuilder
    private func checksGlyph(_ pullRequest: GitHubPullRequest) -> some View {
        switch pullRequest.checks {
        case .passing: OctetIcon("checkmark", size: 10).foregroundStyle(Theme.success)
        case .failing: OctetIcon("xmark", size: 10).foregroundStyle(Theme.danger)
        case .pending: Circle().fill(StatusBarStyle.amber).frame(width: 5, height: 5)
        case .none: EmptyView()
        }
    }

    /// The servers the pane's programs listen on, as the sidebar and the
    /// Browser plane name them: "localhost:3000" with what serves it. A
    /// click opens the first in the Browser plane; the menu offers the
    /// default browser and the rest.
    @ViewBuilder
    private func portsItem(_ descriptor: StatusItemDescriptor, _ output: StatusItemOutput) -> some View {
        let found = StatusBarItems.ports(in: output.text)
        if let first = found.first, let url = Self.localURL(first) {
            Button { ui.openInBrowserPlane(url) } label: {
                StatusChip(help: (output.help.map { $0 + "\n" } ?? "") + "Click to open in the Browser plane") {
                    if let logo = LanguageLogo(service: ports.services[first], size: 13) {
                        logo
                    } else {
                        OctetIcon("global", size: 13)
                    }
                    Text("localhost:\(String(first))").font(Theme.monoFont)
                    if found.count > 1 {
                        Text("+\(found.count - 1)").foregroundStyle(Theme.textTertiary)
                    }
                }
            }
            .buttonStyle(.plain)
            .modifier(LinkHover())
            .contextMenu {
                if found.count == 1 {
                    portActions(first)
                } else {
                    ForEach(found, id: \.self) { port in
                        Menu("localhost:\(String(port))") { portActions(port) }
                    }
                }
            }
        } else {
            pluginItem(descriptor, output)
        }
    }

    @ViewBuilder
    private func portActions(_ port: Int) -> some View {
        if let url = Self.localURL(port) {
            Button("Open in Browser Plane") { ui.openInBrowserPlane(url) }
            Button("Open in Default Browser") { openURL(url) }
            Button("Copy URL") { copy(url.absoluteString) }
        }
    }

    private static func localURL(_ port: Int) -> URL? { URL(string: "http://localhost:\(port)") }

    @ViewBuilder
    private func pluginItem(_ descriptor: StatusItemDescriptor, _ output: StatusItemOutput) -> some View {
        let content = StatusChip(tone: output.tone, help: output.help ?? descriptor.name) {
            StatusItemIcon(descriptor: descriptor, size: 13, tinted: output.tone == .normal)
            Text(output.text).lineLimit(1)
        }
        if let url = output.url, case .pluginSettings(let id)? = OctetURL(url),
           let plugin = plugins.plugins.first(where: { $0.id == id }) {
            // What the plugin needs, asked right here on the item.
            Button { setupShown = setupShown == descriptor.id ? nil : descriptor.id } label: { content }
                .buttonStyle(.plain)
                .modifier(LinkHover())
                .popover(isPresented: Binding(get: { setupShown == descriptor.id },
                                              set: { if !$0, setupShown == descriptor.id { setupShown = nil } }),
                         arrowEdge: .top) {
                    PluginSetupPopover(plugin: plugin) { setupShown = nil }
                }
        } else if let url = output.url {
            Button {
                if let link = OctetURL(url) { OctetURLHandler.handle(link) } else { openURL(url) }
            } label: { content }
                .buttonStyle(.plain)
                .modifier(LinkHover())
        } else {
            content
        }
    }

    @ViewBuilder
    private func worktreeActions(_ repo: StatusBarModel.Repo) -> some View {
        if let main = GitBranch.mainCheckout(ofWorktreeGitDir: repo.gitDir) {
            Button("Open Main Checkout") { WindowRegistry.shared.key?.openProject(path: main) }
        }
        Button("Show Worktrees") { ui.showPlane(.git) }
        Divider()
        Button("Reveal in Finder") { NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: repo.root)]) }
        Button("Copy Path") { copy(repo.root) }
    }

    /// `worktreeActions` as Octet menu items, for the chip's click.
    private func worktreeMenuItems(_ repo: StatusBarModel.Repo) -> [OctetMenuItem] {
        var items: [OctetMenuItem] = []
        if let main = GitBranch.mainCheckout(ofWorktreeGitDir: repo.gitDir) {
            items.append(.action("Open Main Checkout") { WindowRegistry.shared.key?.openProject(path: main) })
        }
        items.append(.action("Show Worktrees") { ui.showPlane(.git) })
        items.append(.divider)
        items.append(.action("Reveal in Finder") {
            NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: repo.root)])
        })
        items.append(.action("Copy Path") { copy(repo.root) })
        return items
    }

    private func copy(_ text: String) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
    }
}

/// The hairline between runs of related items.
private struct StatusBarDivider: View {
    var body: some View {
        Rectangle()
            .fill(Theme.divider)
            .frame(width: 1, height: 12)
            .padding(.horizontal, 4)
            .accessibilityHidden(true)
    }
}

/// The footer's type and colours, shared by its items.
enum StatusBarStyle {
    static var font: Font { Theme.interfaceFont(11.5) }
    /// T3 Code's amber, for something running or wanting a look.
    static var amber: Color { PullRequestStyle.amber }
}

/// One footer item: a 24pt run of a 13pt icon and 11.5pt text, in the
/// secondary text colour, with no frame of its own. It fills on hover so it
/// still reads as something to point at. A tone recolours it only when it's
/// warning of something (or `tint` names a colour, for the SSH host).
struct StatusChip<Content: View>: View {

    var tone: StatusItemOutput.Tone = .normal
    var tint: Color?
    var help: String?
    /// A band of light passing over it, for something live elsewhere.
    var glimmer = false
    @ViewBuilder let content: Content
    @State private var hovered = false

    var body: some View {
        HStack(spacing: 5) { content }
            .font(StatusBarStyle.font.monospacedDigit())
            .foregroundStyle(foreground)
            .padding(.horizontal, 7)
            .frame(height: 24)
            .background(RoundedRectangle(cornerRadius: Theme.Radius.md).fill(hovered ? Theme.hover : Color.clear))
            .overlay { if glimmer { RemoteGlimmer(cornerRadius: Theme.Radius.md) } }
            .contentShape(RoundedRectangle(cornerRadius: Theme.Radius.md))
            .fixedSize()
            .onHover { hovered = $0 }
            .modifier(OptionalHelp(text: help))
    }

    private var foreground: Color {
        switch tone {
        case .warning: StatusBarStyle.amber
        case .danger: Theme.danger
        case .success: Theme.success
        case .muted: Theme.textTertiary
        case .normal: tint ?? Theme.textSecondary
        }
    }
}

/// A tooltip only when there's something to say: an empty `.help("")`
/// still takes the hover.
struct OptionalHelp: ViewModifier {
    let text: String?

    func body(content: Content) -> some View {
        if let text, !text.isEmpty { content.help(text) } else { content }
    }
}

/// Reports where an item sits in the status bar as it scrolls.
private struct StatusItemSpanReader: View {
    static let space = "statusBar"
    let id: String

    var body: some View {
        GeometryReader { proxy in
            let frame = proxy.frame(in: .named(Self.space))
            Color.clear.preference(key: StatusItemSpansKey.self,
                                   value: [id: .init(id: id, minX: frame.minX, maxX: frame.maxX)])
        }
    }
}

private struct StatusItemSpansKey: PreferenceKey {
    static let defaultValue: [String: StatusBarOverflow.Span] = [:]
    static func reduce(value: inout [String: StatusBarOverflow.Span], nextValue: () -> [String: StatusBarOverflow.Span]) {
        value.merge(nextValue()) { _, new in new }
    }
}

private struct StatusBarWidthKey: PreferenceKey {
    static let defaultValue: CGFloat = 0
    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) { value = max(value, nextValue()) }
}

/// An SF Symbol sitting in the same 13pt box as an OctetIcon.
struct StatusGlyph: View {
    let symbol: String

    var body: some View {
        OctetIcon(symbol, size: 12)
            .frame(width: 13, height: 13)
    }
}

/// An item that opens something: the pointing hand on hover, so it reads as
/// a link and not as a label (the fill comes from the item itself).
struct LinkHover: ViewModifier {
    var enabled = true
    @State private var pushed = false

    func body(content: Content) -> some View {
        content
            .onHover { inside in
                guard enabled else { return }
                if inside, !pushed {
                    NSCursor.pointingHand.push()
                    pushed = true
                } else if !inside, pushed {
                    NSCursor.pop()
                    pushed = false
                }
            }
            // An item that vanishes under the pointer (the PR merged, CI
            // finished) would otherwise leave the hand pushed.
            .onDisappear {
                if pushed { NSCursor.pop() }
                pushed = false
            }
    }
}

/// An item's icon: a plugin's image tinted like a runtime icon, or an SF
/// Symbol, in the plugin's colour when `tinted` (its brand, kept off the
/// text so the footer stays quiet).
struct StatusItemIcon: View {
    let descriptor: StatusItemDescriptor
    var size: CGFloat = 11
    var tinted = false

    var body: some View {
        if let path = descriptor.iconPath {
            RuntimeIcon(badge: RuntimeBadge(id: descriptor.id, name: descriptor.name, iconPath: path, color: descriptor.color), size: size)
        } else if let symbol = descriptor.symbol {
            OctetIcon(symbol, size: size * 0.93)
                .frame(width: size, height: size)
                .foregroundStyle(tint)
        }
    }

    private var tint: AnyShapeStyle {
        guard tinted, let color = descriptor.color else { return AnyShapeStyle(ForegroundStyle()) }
        let palette = Theme.palette
        return AnyShapeStyle(Color(hex: ThemePalette.readable(color, on: palette.background, toward: palette.textPrimary, minimum: 3)))
    }
}

/// The machine a pane is logged into, in the accent colour so it reads as
/// "not here" at a glance. A light sweeps across it once as it arrives.
struct SSHHostChip: View {
    let target: SSHTarget
    var compact = false
    @ObservedObject private var motion = MotionPreferences.shared
    @State private var sweep: CGFloat = -0.4

    var body: some View {
        HStack(spacing: compact ? 3 : 5) {
            OctetIcon("network", size: compact ? 10 : 12)
            Text(compact ? target.host : target.display)
                .lineLimit(1)
                .truncationMode(.middle)
        }
        .font(compact ? Theme.captionFont : Theme.monoFont)
        .foregroundStyle(Theme.accent)
        .padding(.horizontal, compact ? 5 : 7)
        .frame(height: compact ? 16 : 22)
        .background(RoundedRectangle(cornerRadius: compact ? 4 : 6).fill(Theme.accent.opacity(0.14)))
        .overlay(RoundedRectangle(cornerRadius: compact ? 4 : 6).strokeBorder(Theme.accent.opacity(0.45)))
        .overlay {
            GeometryReader { proxy in
                LinearGradient(colors: [.clear, Theme.accent.opacity(0.45), .clear], startPoint: .leading, endPoint: .trailing)
                    .frame(width: proxy.size.width * 0.4)
                    .offset(x: sweep * proxy.size.width)
            }
            .clipShape(RoundedRectangle(cornerRadius: compact ? 4 : 6))
            .allowsHitTesting(false)
        }
        .help("Connected over SSH to \(target.display)")
        .accessibilityLabel("SSH to \(target.display)")
        .onAppear {
            guard motion.animates(.connections) else { return }
            withAnimation(.easeInOut(duration: 0.9).delay(0.15)) { sweep = 1.1 }
        }
    }
}

/// Shown over the terminal for a moment when the focused pane connects:
/// this Mac, a stream of packets, the other machine, and its name.
struct SSHConnectCard: View {
    let target: SSHTarget
    @ObservedObject private var motion = MotionPreferences.shared
    @State private var start = Date()
    @State private var landed = false

    var body: some View {
        HStack(spacing: Theme.Space.lg) {
            OctetIcon("laptopcomputer", size: 20)
                .foregroundStyle(Theme.textSecondary)
            // With motion off the stream is drawn already arrived.
            if motion.animates(.connections) {
                TimelineView(.animation) { timeline in
                    packets(phase: min(1, timeline.date.timeIntervalSince(start) / 1.2))
                }
            } else {
                packets(phase: 1)
            }
            OctetIcon("server.rack", size: 20)
                .foregroundStyle(Theme.accent)
                .scaleEffect(landed ? 1 : 0.7)
            VStack(alignment: .leading, spacing: 1) {
                Text("Connected")
                    .font(Theme.captionFont)
                    .foregroundStyle(Theme.textTertiary)
                Text(target.display)
                    .font(Theme.monoFont.weight(.medium))
                    .foregroundStyle(Theme.textPrimary)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
        }
        .padding(.horizontal, Theme.Space.xl)
        .padding(.vertical, Theme.Space.md + 2)
        .background(RoundedRectangle(cornerRadius: Theme.Radius.xl).fill(Theme.card))
        .overlay(RoundedRectangle(cornerRadius: Theme.Radius.xl).strokeBorder(Theme.accent.opacity(0.4)))
        .shadow(color: .black.opacity(0.3), radius: 16, y: 6)
        .onAppear {
            start = Date()
            guard motion.animates(.connections) else { landed = true; return }
            withAnimation(.spring(response: 0.35, dampingFraction: 0.55).delay(0.9)) { landed = true }
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel("Connected to \(target.display)")
    }

    private func packets(phase: Double) -> some View {
        HStack(spacing: 5) {
            ForEach(0..<5, id: \.self) { dot in
                Circle()
                    .fill(Theme.accent)
                    .frame(width: 4, height: 4)
                    .opacity(Self.pulse(dot, phase: phase))
            }
        }
    }

    /// Each dot lights as the stream passes it, then settles on.
    private static func pulse(_ dot: Int, phase: Double) -> Double {
        let position = Double(dot) / 4
        return phase >= 1 ? 1 : max(0.2, 1 - abs(phase * 1.4 - position) * 3)
    }
}

/// A commit's CI, workflow by workflow: what's running, what failed and
/// where, with the failure one click from the agent.
private struct CIPopover: View {
    let status: CIStatus
    let branch: String?
    let hasAgent: Bool
    let rerun: () -> Void
    let askAgent: () -> Void
    let refresh: () -> Void
    @Environment(\.openURL) private var openURL

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 6) {
                Text("CI").font(Theme.uiFontMedium).foregroundStyle(Theme.textPrimary)
                if let branch {
                    Text(branch).font(Theme.monoFont).foregroundStyle(Theme.textSecondary).lineLimit(1).truncationMode(.middle)
                }
                Text(status.shortSha).font(Theme.monoFont).foregroundStyle(Theme.textTertiary)
                Spacer(minLength: 8)
                Button(action: refresh) {
                    OctetIcon("arrow.clockwise", size: 11).foregroundStyle(Theme.textSecondary)
                }
                .buttonStyle(.plain)
                .help("Check now")
                .accessibilityLabel("Check now")
            }
            if !status.isHead {
                Text("This commit has no runs yet (not pushed, or not started). These are for \(status.shortSha), the latest pushed.")
                    .font(Theme.captionFont)
                    .foregroundStyle(Theme.textTertiary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            VStack(alignment: .leading, spacing: 2) {
                ForEach(status.runs) { run in CIRunRow(run: run) { if let url = run.url { openURL(url) } } }
            }
            if status.overall == .failed {
                HStack(spacing: 6) {
                    if hasAgent {
                        OctetButton(title: "Ask Agent to Fix", icon: "sparkles", kind: .primary, compact: true, action: askAgent)
                    }
                    OctetButton(title: "Re-run Failed", icon: "arrow.clockwise", kind: .secondary, compact: true, action: rerun)
                }
            }
        }
        .padding(12)
        .frame(width: 320, alignment: .leading)
        .background(Theme.chrome)
    }
}

private struct CIRunRow: View {
    let run: CIRun
    let open: () -> Void
    @State private var hovered = false

    var body: some View {
        Button(action: open) {
            HStack(alignment: .top, spacing: 8) {
                glyph.frame(width: 14, height: 16)
                VStack(alignment: .leading, spacing: 2) {
                    HStack(spacing: 6) {
                        Text(run.workflow).font(Theme.uiFont).foregroundStyle(Theme.textPrimary).lineLimit(1)
                        Spacer(minLength: 4)
                        Text(when).font(Theme.captionFont.monospacedDigit()).foregroundStyle(Theme.textTertiary)
                    }
                    ForEach(run.failedJobs, id: \.self) { job in
                        Text(job).font(Theme.captionFont).foregroundStyle(Theme.danger).lineLimit(2)
                    }
                }
            }
            .padding(.horizontal, 6)
            .padding(.vertical, 4)
            .background(RoundedRectangle(cornerRadius: Theme.rowRadius).fill(hovered ? Theme.hover : Color.clear))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hovered = $0 }
        .help("Open this run on GitHub")
    }

    @ViewBuilder
    private var glyph: some View {
        switch run.state {
        case .queued: Circle().strokeBorder(Theme.textTertiary, lineWidth: 1.2).frame(width: 8, height: 8)
        case .running: LoadingLine(width: 12, color: Theme.accent)
        case .passed: Text("✓").font(Theme.monoFont).foregroundStyle(Theme.success)
        case .failed: Text("✗").font(Theme.monoFont).foregroundStyle(Theme.danger)
        case .cancelled, .skipped: Text("–").font(Theme.monoFont).foregroundStyle(Theme.textTertiary)
        }
    }

    /// How long a finished run took, or how long ago one in progress began.
    private var when: String {
        guard let start = run.createdAt else { return "" }
        if run.isFinished, let end = run.updatedAt {
            let seconds = Int(end.timeIntervalSince(start))
            return seconds >= 60 ? "\(seconds / 60)m \(seconds % 60)s" : "\(seconds)s"
        }
        return UsageMeter.relative(start)
    }
}
