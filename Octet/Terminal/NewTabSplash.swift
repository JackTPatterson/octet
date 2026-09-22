import SwiftUI

/// Which tab shows the new-tab splash right now, fed one grid reading at a
/// time by the terminal. The deciding is `NewTabFreshness`; this only
/// publishes the answer.
@MainActor
final class NewTabSplashModel: ObservableObject {
    @Published private(set) var tabId: String?
    private var freshness = NewTabFreshness()
    /// The last reading, kept to look at again once it can be believed.
    private var latest: (tab: String?, grid: TerminalGrid?, eligible: Bool, typing: Bool)?
    private var recheck: DispatchWorkItem?

    /// One reading of the grid for the tab in front. `eligible` is false
    /// while something else owns the terminal area (a conversation, a board,
    /// a split, a running program), which leaves the tab's state untouched.
    /// `typing` is Octet's own command line holding text: it keeps a command
    /// until Return, so the shell's cursor doesn't move while it's typed.
    func observe(tab: String?, grid: TerminalGrid?, eligible: Bool, typing: Bool) {
        latest = (tab, grid, eligible, typing)
        evaluate()
    }

    private func evaluate() {
        guard let latest else { return }
        var shown: String?
        if latest.eligible, let tab = latest.tab, let grid = latest.grid {
            let now = Date()
            if freshness.observe(tab: tab, cursorRow: grid.cursorRow, cursorColumn: grid.cursorColumn,
                                 rowsInUse: grid.rowsInUse, at: now), !latest.typing {
                shown = tab
            }
            // The terminal only reports changes, so a grid that has stopped
            // changing would never be judged: look again once it counts.
            if let settles = freshness.settles(tab: tab, at: now) {
                recheck?.cancel()
                let work = DispatchWorkItem { [weak self] in self?.evaluate() }
                recheck = work
                DispatchQueue.main.asyncAfter(deadline: .now() + settles.timeIntervalSince(now) + 0.02, execute: work)
            }
        }
        if shown != tabId { tabId = shown }
    }
}

/// What a new terminal tab offers before anything has run in it.
///
/// Drawn in the blank rows above a bottom-anchored prompt (or below a top one),
/// never over it. The way editors fill an empty pane: VS Code and Zed list
/// their commands with the keys that run them, so the keys get learned;
/// Cursor-style launchers put agents and recent folders first. Everything
/// here acts on this tab: an agent starts in its shell, a folder is `cd`'d
/// into, and the keys shown are the ones that already work from the terminal.
struct NewTabSplash: View {
    struct Shortcut: Identifiable {
        let title: String
        var keys: String?
        var agent: String?
        let run: () -> Void
        var id: String { title }
    }

    /// The folder the tab's shell is in, left out of the recent folders.
    let currentDirectory: String?
    let runAgent: (DiscoveredAgent) -> Void
    let openFolder: (String) -> Void
    let shortcuts: [Shortcut]
    @ObservedObject private var discovery = AgentDiscoveryStore.shared
    @State private var folders: [String] = RecentFolders.cached

    private var agents: [DiscoveredAgent] { discovery.agents.filter { $0.executablePath != nil } }
    private var availableShortcuts: [Shortcut] {
        let installed = Set(agents.map(\.id))
        return shortcuts.filter { $0.agent.map(installed.contains) ?? true }
    }

    private var recent: [String] {
        folders.filter { $0 != currentDirectory }.prefix(4).map { $0 }
    }

    var body: some View {
        // Short windows drop the parts that matter least first: folders,
        // then the shortcuts, keeping the agents.
        ViewThatFits(in: .vertical) {
            content(folders: true, shortcuts: true)
            content(folders: false, shortcuts: true)
            content(folders: false, shortcuts: false)
        }
        .frame(maxWidth: 460)
        .padding(.horizontal, 24)
        .task { folders = await RecentFolders.load() }
    }

    private func content(folders showFolders: Bool, shortcuts showShortcuts: Bool) -> some View {
        VStack(alignment: .leading, spacing: 22) {
            if !agents.isEmpty {
                section("Start an agent here") {
                    // Wraps onto a second line rather than overflowing.
                    SplashFlow(spacing: 8) {
                        ForEach(agents) { agent in
                            AgentChip(agent: agent) { runAgent(agent) }
                        }
                    }
                }
            }
            if showFolders, !recent.isEmpty {
                section("Open a recent folder here") {
                    VStack(spacing: 1) {
                        ForEach(recent, id: \.self) { path in
                            FolderRow(path: path) { openFolder(path) }
                        }
                    }
                }
            }
            if showShortcuts {
                VStack(spacing: 1) {
                    ForEach(availableShortcuts) { shortcut in
                        ShortcutRow(shortcut: shortcut)
                    }
                }
            }
        }
        .fixedSize(horizontal: false, vertical: true)
    }

    private func section<Content: View>(_ title: String, @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(title.uppercased())
                .font(Theme.headerFont)
                .kerning(0.4)
                .foregroundStyle(Theme.textTertiary)
                .padding(.leading, 2)
            content()
        }
    }
}

/// An agent to start in this tab: its mark and name.
private struct AgentChip: View {
    let agent: DiscoveredAgent
    let action: () -> Void
    @State private var hovered = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: 7) {
                if let brand = AgentBrand.forAgent(agent.id) { AgentLogo(brand: brand, size: 13) }
                Text(agent.displayName)
                    .font(Theme.uiFont)
                    .foregroundStyle(Theme.textPrimary)
            }
            .padding(.horizontal, 11)
            .frame(height: 30)
            .background(hovered ? Theme.hover : Theme.card)
            .overlay(RoundedRectangle(cornerRadius: Theme.rowRadius + 2).strokeBorder(Theme.border, lineWidth: 1))
            .clipShape(RoundedRectangle(cornerRadius: Theme.rowRadius + 2))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hovered = $0 }
        .help("Run \(agent.onShellPath == true ? agent.command : agent.executablePath ?? agent.command) in this tab")
        .accessibilityLabel("Start \(agent.displayName) in this tab")
    }
}

/// A recent folder: its name, where it is, and a `cd` into it on click.
private struct FolderRow: View {
    let path: String
    let action: () -> Void
    @State private var hovered = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: 9) {
                OctetIcon("folder", size: 14)
                    .foregroundStyle(Theme.textTertiary)
                Text((path as NSString).lastPathComponent)
                    .font(Theme.uiFont)
                    .foregroundStyle(Theme.textPrimary)
                    .lineLimit(1)
                Text(abbreviateHome((path as NSString).deletingLastPathComponent))
                    .font(Theme.captionFont)
                    .foregroundStyle(Theme.textTertiary)
                    .lineLimit(1)
                    .truncationMode(.middle)
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 8)
            .frame(height: 28)
            .background(hovered ? Theme.hover : Color.clear)
            .clipShape(RoundedRectangle(cornerRadius: Theme.rowRadius + 2))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hovered = $0 }
        .help("cd \(abbreviateHome(path))")
        .accessibilityLabel("Change to \((path as NSString).lastPathComponent)")
    }
}

/// A command and the keys that run it, the way an editor's empty pane lists
/// them. The keys already work from the terminal; a click does the same.
private struct ShortcutRow: View {
    let shortcut: NewTabSplash.Shortcut
    @State private var hovered = false

    var body: some View {
        Button(action: shortcut.run) {
            HStack {
                Text(shortcut.title)
                    .font(Theme.uiFont)
                    .foregroundStyle(hovered ? Theme.textPrimary : Theme.textSecondary)
                Spacer(minLength: 16)
                if let keys = shortcut.keys { Keycap(text: keys) }
            }
            .padding(.horizontal, 8)
            .frame(height: 28)
            .background(hovered ? Theme.hover : Color.clear)
            .clipShape(RoundedRectangle(cornerRadius: Theme.rowRadius + 2))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hovered = $0 }
        .accessibilityLabel(shortcut.title)
        .accessibilityHint(shortcut.keys.map { "Keyboard shortcut \($0)" } ?? "")
    }
}

/// Chips laid out in rows, wrapping when the next one doesn't fit.
private struct SplashFlow: Layout {
    var spacing: CGFloat = 8

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let width = proposal.width ?? .infinity
        var x: CGFloat = 0, y: CGFloat = 0, rowHeight: CGFloat = 0, widest: CGFloat = 0
        for subview in subviews {
            let size = subview.sizeThatFits(.unspecified)
            if x > 0, x + size.width > width {
                y += rowHeight + spacing
                x = 0
                rowHeight = 0
            }
            x += size.width + spacing
            rowHeight = max(rowHeight, size.height)
            widest = max(widest, x - spacing)
        }
        return CGSize(width: widest, height: y + rowHeight)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        var x = bounds.minX, y = bounds.minY, rowHeight: CGFloat = 0
        for subview in subviews {
            let size = subview.sizeThatFits(.unspecified)
            if x > bounds.minX, x + size.width > bounds.maxX {
                y += rowHeight + spacing
                x = bounds.minX
                rowHeight = 0
            }
            subview.place(at: CGPoint(x: x, y: y), proposal: ProposedViewSize(size))
            x += size.width + spacing
            rowHeight = max(rowHeight, size.height)
        }
    }
}

/// Recently touched project folders, as the palette lists them. Reading
/// them walks the project folders on disk, so it happens off the main thread
/// and the last answer is kept for the next splash.
enum RecentFolders {
    @MainActor static var cached: [String] = []

    @MainActor
    static func load() async -> [String] {
        let folders = await Task.detached(priority: .utility) { ProjectDirectories.list() }.value
        cached = folders
        return folders
    }
}
