import Foundation

/// Which tab gets the new-tab splash, judged from what its grid shows.
///
/// A tab is fresh while it has shown nothing but its first prompt. Once it
/// runs anything it is used for good: an empty screen after `clear` is the
/// person's own doing, and a splash coming back then would be in the way.
///
/// The engine draws every tab through one terminal surface, so a reading
/// belongs to whichever tab is in front, and just after switching tabs the
/// grid can still show the one before. Readings in that moment are held back
/// from deciding anything. It's measured in time, not in readings, because the
/// terminal reports only when the grid changes: once output settles there is
/// no next reading to wait for.
struct NewTabFreshness {
    /// Rows a prompt may take: a blank line and a two-line theme.
    static let promptRows = 3
    /// How long after a tab comes to the front before its grid is believed.
    /// The engine redraws well within it.
    static let settleDelay: TimeInterval = 0.5

    private(set) var used: Set<String> = []
    /// The row each tab's first prompt sat on. A command sends the cursor
    /// below it, even one like `cd` that prints nothing.
    private var promptRow: [String: Int] = [:]
    /// Where the cursor waits on that row with nothing typed: the leftmost it
    /// has been there, so a prompt redrawn mid-typing can't move it right.
    private var promptColumn: [String: Int] = [:]
    private var inFront: (tab: String, since: Date)?

    /// Whether `tab` should show the splash, given one reading of its grid:
    /// the cursor's position and how many rows through it hold text.
    mutating func observe(tab: String, cursorRow: Int, cursorColumn: Int = 0, rowsInUse: Int,
                          at now: Date = Date()) -> Bool {
        if inFront?.tab != tab { inFront = (tab, now) }
        guard !used.contains(tab) else { return false }
        let settled = settles(tab: tab, at: now) == nil
        let movedOn = promptRow[tab].map { cursorRow > $0 } ?? false
        if rowsInUse > Self.promptRows || movedOn {
            // Hidden either way; only a settled reading can make it final.
            if settled {
                used.insert(tab)
                promptRow[tab] = nil
                promptColumn[tab] = nil
            }
            return false
        }
        if settled, promptRow[tab] == nil, rowsInUse > 0 { promptRow[tab] = cursorRow }
        // A command being typed hides it, without using the tab: clear the
        // line and it's back.
        if promptRow[tab] == cursorRow {
            let start = min(promptColumn[tab] ?? cursorColumn, cursorColumn)
            promptColumn[tab] = start
            if cursorColumn > start { return false }
        }
        return true
    }

    /// When a reading of `tab` will be believed, if not yet: the caller looks
    /// again then, so a grid that has stopped changing still gets judged.
    func settles(tab: String, at now: Date) -> Date? {
        guard let inFront, inFront.tab == tab else { return nil }
        let at = inFront.since.addingTimeInterval(Self.settleDelay)
        return at > now ? at : nil
    }

    /// The tab closed; its id won't come back.
    mutating func forget(_ tab: String) {
        used.remove(tab)
        promptRow[tab] = nil
        promptColumn[tab] = nil
        if inFront?.tab == tab { inFront = nil }
    }
}
