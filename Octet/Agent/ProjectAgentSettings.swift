import AppKit
import SwiftUI
import Foundation

/// Reading and writing the project's allow rules (`.claude/settings.local.json`).
enum ProjectRules {
    static func add(_ rule: String, cwd: String) throws {
        let path = AgentPermissionRules.localSettingsPath(cwd: cwd)
        let existing = FileManager.default.contents(atPath: path)
        guard let data = AgentPermissionRules.adding(rule, to: existing) else {
            throw Problem("\(path) isn't plain JSON; add \(rule) under permissions.allow by hand.")
        }
        try FileManager.default.createDirectory(atPath: (path as NSString).deletingLastPathComponent, withIntermediateDirectories: true)
        try data.write(to: URL(fileURLWithPath: path), options: .atomic)
    }

    static func remove(_ rule: String, cwd: String) throws {
        let path = AgentPermissionRules.localSettingsPath(cwd: cwd)
        guard let existing = FileManager.default.contents(atPath: path) else { return }
        guard let data = AgentPermissionRules.removing(rule, from: existing) else {
            throw Problem("\(path) isn't plain JSON; remove \(rule) by hand.")
        }
        try data.write(to: URL(fileURLWithPath: path), options: .atomic)
    }

    /// Rules Octet and Claude Code keep for this person in this project.
    static func local(cwd: String) -> [String] {
        AgentPermissionRules.allowRules(in: FileManager.default.contents(atPath: AgentPermissionRules.localSettingsPath(cwd: cwd)))
    }

    /// Rules checked into the project, which are the team's to change.
    static func shared(cwd: String) -> [String] {
        AgentPermissionRules.allowRules(in: FileManager.default.contents(atPath: AgentPermissionRules.sharedSettingsPath(cwd: cwd)))
    }

    struct Problem: LocalizedError {
        let message: String
        init(_ message: String) { self.message = message }
        var errorDescription: String? { message }
    }
}

/// The project's instructions files and allow rules, for the right panel's
/// Agent Setup section: whether the agents read the same instructions, and
/// what they've been told they may always do here.
@MainActor
final class ProjectAgentModel: ObservableObject {
    static let changed = Notification.Name("octet.projectAgentSettingsChanged")

    /// Something wrote a rule; every window's model reads again.
    nonisolated static func noteRulesChanged() {
        NotificationCenter.default.post(name: changed, object: nil)
    }

    @Published private(set) var root: String?
    @Published private(set) var instructions: AgentInstructions.State = .none
    @Published private(set) var localRules: [String] = []
    @Published private(set) var sharedRules: [String] = []
    @Published private(set) var busy = false

    private weak var window: WindowContext?
    private var timer: Timer?
    private var observer: NSObjectProtocol?
    private var reading = false

    static let interval: TimeInterval = 5

    func attach(_ window: WindowContext) {
        guard self.window !== window else { return }
        self.window = window
        refresh()
        timer?.invalidate()
        timer = Timer.scheduledTimer(withTimeInterval: Self.interval, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.refresh() }
        }
        observer = NotificationCenter.default.addObserver(forName: Self.changed, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.refresh(force: true) }
        }
    }

    /// Whether the section has anything to say: the instructions need
    /// sharing between agents that would read them, or there are rules.
    var hasContent: Bool { needsSharing || !localRules.isEmpty || !sharedRules.isEmpty }

    /// The instructions are in one agent's file only, and another agent that
    /// reads the other file is installed.
    var needsSharing: Bool { instructions.needsAction && Self.otherAgentsInstalled }

    private static var otherAgentsInstalled: Bool {
        let installed = Set(AgentDiscoveryStore.shared.agents.filter { $0.executablePath != nil }.map(\.id))
        return installed.contains("claude") && !installed.isDisjoint(with: ["codex", "opencode", "pi"])
    }

    /// The folder the instructions belong to: where the repository starts,
    /// else the workspace's folder.
    private func folder() -> String? {
        guard let window, let workspace = window.focusedWorkspace?.workspaceId else { return nil }
        let snapshot = window.store.snapshot
        return window.focusedPaneId.flatMap { snapshot.workingDirectory(ofPane: $0) }
            ?? snapshot.directory(ofWorkspace: workspace)
    }

    #if DEBUG
    /// Verification and demos: made-up rules. Nothing is read or written.
    private var sampling = false

    func loadSample() {
        sampling = true
        localRules = ["Bash(git status:*)", "Bash(git diff:*)", "Bash(git log:*)", "Bash(npm test:*)", "Bash(npm run build:*)",
                      "Bash(swift test:*)", "Bash(xcodegen generate)", "Bash(ls:*)", "WebFetch(domain:docs.swift.org)",
                      "mcp__linear__create_issue", "mcp__linear__list_issues"]
        sharedRules = ["Bash(make lint:*)", "Read(~/Developer/**)"]
    }
    #endif

    func refresh(force: Bool = false) {
        #if DEBUG
        if sampling { return }
        #endif
        guard let window, !reading else { return }
        // Only while the panel is showing the overview, unless something changed.
        guard force || window.ui.showing(.overview) else { return }
        guard let directory = folder() else {
            if root != nil { root = nil; instructions = .none; localRules = []; sharedRules = [] }
            return
        }
        reading = true
        DispatchQueue.global(qos: .utility).async {
            let top = Git().topLevel(directory) ?? directory
            let files = Self.files(in: top)
            let state = AgentInstructions.state(of: files)
            let local = ProjectRules.local(cwd: directory)
            let shared = ProjectRules.shared(cwd: directory)
            DispatchQueue.main.async {
                MainActor.assumeIsolated {
                    self.reading = false
                    if self.root != top { self.root = top }
                    if self.instructions != state { self.instructions = state }
                    if self.localRules != local { self.localRules = local }
                    if self.sharedRules != shared { self.sharedRules = shared }
                }
            }
        }
    }

    nonisolated private static func files(in top: String) -> AgentInstructions.Files {
        let manager = FileManager.default
        let agentsPath = (top as NSString).appendingPathComponent("AGENTS.md")
        let claudePath = (top as NSString).appendingPathComponent("CLAUDE.md")
        func read(_ path: String) -> String? {
            manager.contents(atPath: path).map { String(decoding: $0, as: UTF8.self) }
        }
        var linked = false
        if let target = try? manager.destinationOfSymbolicLink(atPath: claudePath) {
            let resolved = target.hasPrefix("/") ? target : (top as NSString).appendingPathComponent(target)
            linked = (resolved as NSString).standardizingPath == (agentsPath as NSString).standardizingPath
        }
        return AgentInstructions.Files(agents: read(agentsPath), claude: read(claudePath), claudeLinksToAgents: linked)
    }

    // MARK: - Sharing the instructions

    /// Asks, saying what will be written, then makes the instructions shared.
    func shareInstructions() {
        // Read now, not from the last refresh: this may be the palette, with the panel closed.
        guard let directory = folder() else {
            ToastCenter.shared.info("Open a project first")
            return
        }
        let root = Git().topLevel(directory) ?? directory
        let files = Self.files(in: root)
        guard AgentInstructions.state(of: files) != .none else {
            ToastCenter.shared.info("No instructions to share", detail: "There's no AGENTS.md or CLAUDE.md in \(abbreviateHome(root)).")
            return
        }
        guard let plan = AgentInstructions.plan(for: files) else {
            ToastCenter.shared.info("The instructions are already shared")
            return
        }
        ConfirmCenter.shared.ask(
            title: "Share the instructions with every agent?",
            message: plan.summary,
            items: [(root as NSString).appendingPathComponent("AGENTS.md"), (root as NSString).appendingPathComponent("CLAUDE.md")],
            confirmTitle: "Share"
        ) { [weak self] _ in self?.apply(plan, in: root) }
    }

    private func apply(_ plan: AgentInstructions.Plan, in root: String) {
        busy = true
        DispatchQueue.global(qos: .userInitiated).async {
            let outcome = Result { () throws -> Void in
                let agentsPath = (root as NSString).appendingPathComponent("AGENTS.md")
                let claudePath = (root as NSString).appendingPathComponent("CLAUDE.md")
                // The backup goes first: if anything after fails, nothing is lost.
                if let backup = plan.backupOfClaude {
                    try backup.write(toFile: claudePath + ".octet-backup", atomically: true, encoding: .utf8)
                }
                if let agents = plan.agents { try agents.write(toFile: agentsPath, atomically: true, encoding: .utf8) }
                // A symbolic link is replaced by the file, not written through.
                if (try? FileManager.default.destinationOfSymbolicLink(atPath: claudePath)) != nil {
                    try FileManager.default.removeItem(atPath: claudePath)
                }
                try plan.claude.write(toFile: claudePath, atomically: true, encoding: .utf8)
            }
            DispatchQueue.main.async {
                MainActor.assumeIsolated {
                    self.busy = false
                    switch outcome {
                    case .success:
                        ToastCenter.shared.info("Instructions shared", detail: "CLAUDE.md now imports AGENTS.md. New agent sessions read the same instructions.")
                    case .failure(let error):
                        ToastCenter.shared.fail(nil, "Couldn't share the instructions", detail: error.localizedDescription)
                    }
                    self.refresh(force: true)
                }
            }
        }
    }

    // MARK: - Rules

    /// Takes a rule out of the project's local settings, and out of any
    /// conversation here that was applying it.
    func removeRule(_ rule: String) {
        guard let directory = folder() else { return }
        do {
            try ProjectRules.remove(rule, cwd: directory)
            for session in AgentCenter.shared.sessions where session.cwd == directory { session.forgetAlwaysRule(rule) }
            localRules.removeAll { $0 == rule }
            ToastCenter.shared.info("No longer always allowed", detail: rule)
        } catch {
            ToastCenter.shared.fail(nil, "Couldn't remove the rule", detail: error.localizedDescription)
        }
        refresh(force: true)
    }

    /// Opens the settings file the rules are in.
    func revealRules() {
        guard let directory = folder() else { return }
        let path = AgentPermissionRules.localSettingsPath(cwd: directory)
        if FileManager.default.fileExists(atPath: path) {
            NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: path)])
        }
    }
}

// MARK: - The section

/// Agent Setup in the right panel's Overview: shown only when it has
/// something to say. It starts as one line ("12 allowed commands · 2 MCP");
/// open, it says whether the agents read the same instructions, with the
/// one-click fix, and lists what's always allowed in this project.
struct ProjectAgentSection: View {
    @ObservedObject var model: ProjectAgentModel
    @ObservedObject private var discovery = AgentDiscoveryStore.shared
    @State private var showingShared = false
    @State private var showingAllCommands = false
    @State private var showingAllMCP = false

    var body: some View {
        if model.hasContent {
            SidePanelSectionView(.setup,
                                 label: model.needsSharing ? "Share instructions"
                                     : AgentSetupSummary.summary(rules: model.localRules + model.sharedRules),
                                 labelColor: model.needsSharing ? Theme.warning : nil) {
                VStack(alignment: .leading, spacing: 12) {
                    if model.needsSharing { instructions }
                    if !model.localRules.isEmpty || !model.sharedRules.isEmpty { rules }
                }
            }
        }
    }

    private var instructions: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 6) {
                OctetIcon("exclamationmark.triangle.fill", size: 12).foregroundStyle(Theme.warning)
                Text("Instructions").font(Theme.uiFontMedium).foregroundStyle(Theme.textPrimary)
            }
            Text(model.instructions.summary)
                .font(Theme.captionFont)
                .foregroundStyle(Theme.textSecondary)
                .fixedSize(horizontal: false, vertical: true)
            OctetButton(title: "Share with Every Agent", icon: "sparkles", kind: .secondary, compact: true) {
                model.shareInstructions()
            }
            .disabled(model.busy)
            .help("AGENTS.md holds the instructions and CLAUDE.md imports it. Nothing is lost; you're asked first.")
        }
    }

    private var rules: some View {
        let commands = model.localRules.filter { !AgentSetupSummary.isMCP($0) }
        let mcp = model.localRules.filter(AgentSetupSummary.isMCP)
        return VStack(alignment: .leading, spacing: 10) {
            if !model.localRules.isEmpty {
                group("Commands", rules: commands, showingAll: $showingAllCommands, trailing: true)
                group("MCP tools", rules: mcp, showingAll: $showingAllMCP, trailing: commands.isEmpty)
            }
            if !model.sharedRules.isEmpty {
                VStack(alignment: .leading, spacing: 1) {
                    if !model.localRules.isEmpty {
                        Button {
                            MotionPreferences.shared.perform(.sidebar) { showingShared.toggle() }
                        } label: {
                            HStack(spacing: 4) {
                                OctetIcon("chevron.right", size: 10).rotationEffect(.degrees(showingShared ? 90 : 0))
                                Text("\(model.sharedRules.count) from the project's settings").font(Theme.captionFont)
                            }
                            .foregroundStyle(Theme.textTertiary)
                            .padding(.horizontal, 6)
                            .frame(height: 22)
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                        .accessibilityValue(showingShared ? "Expanded" : "Collapsed")
                    } else {
                        subheading("Allowed by the project")
                    }
                    if model.localRules.isEmpty || showingShared {
                        ForEach(model.sharedRules, id: \.self) { rule in RuleRow(rule: rule, removable: false) {} }
                    }
                }
            }
        }
    }

    private func subheading(_ title: String) -> some View {
        Text(title.uppercased())
            .font(Theme.headerFont).kerning(0.4)
            .foregroundStyle(Theme.textTertiary)
            .padding(.horizontal, 6)
            .padding(.bottom, 2)
    }

    /// One kind of always-allowed rule, the first few and the rest behind
    /// "See all". The first group carries the "Show File" link.
    @ViewBuilder
    private func group(_ title: String, rules: [String], showingAll: Binding<Bool>, trailing: Bool) -> some View {
        if !rules.isEmpty {
            VStack(alignment: .leading, spacing: 1) {
                HStack(spacing: 6) {
                    subheading("\(title) · \(rules.count)")
                    Spacer(minLength: 0)
                    if trailing {
                        Button("Show File") { model.revealRules() }
                            .buttonStyle(.plain).font(Theme.captionFont).foregroundStyle(Theme.textTertiary)
                            .help("Open .claude/settings.local.json in Finder")
                    }
                }
                ForEach(showingAll.wrappedValue ? rules : Array(rules.prefix(6)), id: \.self) { rule in
                    RuleRow(rule: rule, removable: true) { model.removeRule(rule) }
                }
                SidePanelMore(total: rules.count, showingAll: showingAll, shown: 6)
                    .padding(.horizontal, 6)
            }
        }
    }
}

private struct RuleRow: View {
    let rule: String
    let removable: Bool
    let remove: () -> Void
    @State private var hovered = false

    var body: some View {
        HStack(spacing: 6) {
            Text(AgentSetupSummary.display(rule: rule))
                .font(Theme.monoFont)
                .foregroundStyle(removable ? Theme.textPrimary : Theme.textTertiary)
                .lineLimit(1)
                .truncationMode(.middle)
            Spacer(minLength: 4)
            if removable, hovered {
                Button(action: remove) {
                    OctetIcon("xmark", size: 11).foregroundStyle(Theme.textSecondary).frame(width: 18, height: 18).contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .help("Stop always allowing this")
                .accessibilityLabel("Remove \(rule)")
            } else if !removable {
                Text("shared").font(Theme.captionFont).foregroundStyle(Theme.textMuted)
            }
        }
        .padding(.horizontal, 6)
        .frame(height: 24)
        .background(RoundedRectangle(cornerRadius: Theme.controlRadius).fill(hovered ? Theme.hover : Color.clear))
        .onHover { hovered = $0 }
        .help(rule)
    }
}
