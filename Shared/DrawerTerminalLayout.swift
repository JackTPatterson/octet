import Foundation

/// One workspace's shells in the bottom terminal drawer, after T3 Code's:
/// groups of one to four terminals, side by side or stacked, with one
/// terminal in front. Pure state, so the rules (the cap, which terminal
/// takes over when one closes) are tested apart from the views.
struct DrawerTerminalLayout: Codable, Equatable {
    /// How a group's terminals share its space. Named for the split that
    /// makes them, as Octet's Pane menu does: a horizontal split puts the new
    /// terminal to the right, a vertical one below.
    enum Axis: String, Codable {
        case horizontal, vertical
    }

    struct Group: Codable, Equatable, Identifiable {
        var id: Int
        var terminals: [Int]
        var axis: Axis
    }

    /// Past four the shells get too narrow to use, as T3 Code found.
    static let maxPerGroup = 4

    private(set) var groups: [Group]
    /// The terminal in front: the one keys go to and whose group shows.
    private(set) var active: Int
    /// Terminal and group ids share one counter and are never reused, so a
    /// closed shell's view can't be mistaken for a new one.
    private(set) var nextId: Int

    /// A single terminal, which is how every workspace's drawer starts.
    init() {
        groups = [Group(id: 1, terminals: [2], axis: .horizontal)]
        active = 2
        nextId = 3
    }

    /// Every terminal, group by group.
    var terminals: [Int] { groups.flatMap(\.terminals) }

    /// The first terminal: the one agents can be let in to read, and the one
    /// an agent's suggested command is put into.
    var primary: Int? { terminals.first }

    var activeGroup: Group? { groups.first { $0.terminals.contains(active) } }

    /// The sidebar replaces the floating strip once there's more than one.
    var showsSidebar: Bool { terminals.count > 1 }

    /// Group headers only earn their space once a group holds a split.
    var showsGroupHeaders: Bool { groups.contains { $0.terminals.count > 1 } }

    var canSplit: Bool { (activeGroup?.terminals.count ?? 0) < Self.maxPerGroup }

    /// Something saved that can't be shown: no terminals, an active one
    /// that isn't there, an over-full group, or a repeated id.
    var isValid: Bool {
        let all = terminals
        return !all.isEmpty && all.contains(active) && Set(all).count == all.count
            && groups.allSatisfy { !$0.terminals.isEmpty && $0.terminals.count <= Self.maxPerGroup }
            && (all + groups.map(\.id)).allSatisfy { $0 < nextId }
    }

    /// Adds a terminal next to the one in front, in its group, and puts it in
    /// front. A group is all one way, so a split the other way turns the
    /// whole group. Nil when the group is full.
    @discardableResult
    mutating func split(_ axis: Axis) -> Int? {
        guard canSplit, let index = groups.firstIndex(where: { $0.terminals.contains(active) }),
              let position = groups[index].terminals.firstIndex(of: active) else { return nil }
        let id = takeId()
        groups[index].terminals.insert(id, at: position + 1)
        groups[index].axis = axis
        active = id
        return id
    }

    /// A new group of one, after the others, in front.
    @discardableResult
    mutating func newGroup() -> Int {
        let group = takeId()
        let id = takeId()
        groups.append(Group(id: group, terminals: [id], axis: .horizontal))
        active = id
        return id
    }

    /// Puts `id` in front, if it's here.
    mutating func focus(_ id: Int) {
        if terminals.contains(id) { active = id }
    }

    /// Takes a terminal away. If it was in front, its neighbour in the group
    /// takes over (the one before it, else after), else the last terminal of
    /// the group before, else of the one after. Returns false once nothing
    /// is left, when the drawer has no terminal to show.
    @discardableResult
    mutating func close(_ id: Int) -> Bool {
        guard let index = groups.firstIndex(where: { $0.terminals.contains(id) }),
              let position = groups[index].terminals.firstIndex(of: id) else { return !terminals.isEmpty }
        groups[index].terminals.remove(at: position)
        if groups[index].terminals.isEmpty {
            groups.remove(at: index)
            if active == id {
                let neighbour = index > 0 ? groups[index - 1].terminals.last : groups.first?.terminals.first
                if let neighbour { active = neighbour }
            }
        } else if active == id {
            active = groups[index].terminals[max(0, position - 1)]
        }
        return !groups.isEmpty
    }

    /// "Terminal 1", "Terminal 2", … in order, or the shell's own title when
    /// it has set one.
    func label(of id: Int, title: String? = nil) -> String {
        if let title = title?.trimmingCharacters(in: .whitespacesAndNewlines), !title.isEmpty { return title }
        return "Terminal \((terminals.firstIndex(of: id) ?? 0) + 1)"
    }

    /// "Group 1", "Group 2", … in order.
    func groupLabel(of groupId: Int) -> String {
        "Group \((groups.firstIndex { $0.id == groupId } ?? 0) + 1)"
    }

    private mutating func takeId() -> Int {
        defer { nextId += 1 }
        return nextId
    }
}

/// The drawer's own shortcuts, which only apply while one of its shells has
/// the keys; everywhere else the same keys keep doing what Octet's menus say.
enum DrawerTerminalCommand: Equatable {
    case splitHorizontally, splitVertically, newTerminal, close

    /// The command for a Command key, if it's one of the drawer's. `key` is
    /// the key ignoring modifiers (any case).
    static func matching(key: String, command: Bool, shift: Bool, option: Bool, control: Bool) -> Self? {
        guard command, !option, !control else { return nil }
        switch (key.lowercased(), shift) {
        case ("d", false): return .splitHorizontally
        case ("d", true): return .splitVertically
        case ("n", false): return .newTerminal
        case ("w", false): return .close
        default: return nil
        }
    }
}
