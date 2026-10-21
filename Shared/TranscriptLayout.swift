import Foundation

/// What the transcript works out from a conversation's items before it
/// draws: which are shown, its rows, how deep each item sits, and the
/// minimap's prompts. Items are found by their place in `items`, not kept
/// here, so a reply's text is always read fresh.
struct TranscriptLayout: Equatable {
    var rows: [TranscriptRow] = []
    /// Where each shown item sits in the conversation's items, by id.
    var positions: [String: Int] = [:]
    var shownCount = 0
    var lastShownId: String?
    /// Where the last reply is, for Regenerate.
    var lastTextPosition: Int?
    var depths: [String: Int] = [:]
    var thinkingDurations: [String: TimeInterval] = [:]
    var marks: [TranscriptPromptMark] = []

    /// The shown item `id`, as it is now.
    func item(_ id: String, in items: [AgentItem]) -> AgentItem? {
        guard let position = positions[id], items.indices.contains(position) else { return nil }
        return items[position]
    }

    /// Everything worked out from scratch.
    static func make(_ items: [AgentItem]) -> TranscriptLayout {
        make(items, shown: items.indices.filter { TranscriptTimeline.isShown(items[$0]) }).layout
    }

    fileprivate static func make(_ items: [AgentItem], shown positions: [Int])
        -> (layout: TranscriptLayout, sources: [TranscriptPromptMark.Source]) {
        let shown = positions.map { items[$0] }
        var layout = TranscriptLayout()
        layout.rows = TranscriptTimeline.rows(shown)
        layout.positions = Dictionary(zip(shown.map(\.id), positions), uniquingKeysWith: { first, _ in first })
        layout.shownCount = shown.count
        layout.lastShownId = shown.last?.id
        layout.lastTextPosition = items.lastIndex { if case .text = $0.kind { true } else { false } }
        layout.depths = TranscriptTimeline.depths(items)
        layout.thinkingDurations = TranscriptTimeline.thinkingDurations(items)
        let found = TranscriptPromptMark.marksWithSources(shown)
        layout.marks = found.marks
        // The sources point into `shown`; the cache reads `items`.
        let sources = found.sources.map { source in
            TranscriptPromptMark.Source(reply: source.reply.map { positions[$0] }, length: source.length,
                                        saturated: source.saturated, blanks: source.blanks.map { positions[$0] })
        }
        return (layout, sources)
    }
}

/// Keeps a transcript's layout between redraws. While a reply streams only
/// its text grows; the items' ids, kinds, parents and count stay put, and
/// `AgentConversation.structureRevision` doesn't move. So the key is that
/// revision, the count and the last id, compared in constant time, and the
/// rows and the rest are worked out again only when it changes. What does
/// depend on streaming text is checked on its own: a blank thinking block
/// that has words now (it's shown from then on), and the start of each
/// prompt's reply on the minimap.
final class TranscriptLayoutCache {
    private struct Key: Equatable {
        let revision: UInt64
        let count: Int
        let lastId: String?
    }

    private var key: Key?
    private(set) var layout = TranscriptLayout()
    /// Moves on each time the layout is worked out again, for caches that
    /// build on it (the turns' changed files).
    private(set) var generation = 0
    /// Thinking blocks hidden only for being blank, by place in the items.
    private var blankThinking: [Int] = []
    private var sources: [TranscriptPromptMark.Source] = []

    func layout(for conversation: AgentConversation) -> TranscriptLayout {
        let items = conversation.items
        let key = Key(revision: conversation.structureRevision, count: items.count, lastId: items.last?.id)
        if key != self.key || blankThinking.contains(where: { !Self.isBlankThinking(items[$0]) }) {
            rebuild(items, key: key)
        } else {
            refreshMarks(items)
        }
        return layout
    }

    private func rebuild(_ items: [AgentItem], key: Key) {
        let shown = items.indices.filter { TranscriptTimeline.isShown(items[$0]) }
        (layout, sources) = TranscriptLayout.make(items, shown: shown)
        blankThinking = items.indices.filter { !items[$0].queued && Self.isBlankThinking(items[$0]) }
        self.key = key
        generation += 1
    }

    /// A reply that streamed more words since, or a blank one that has its
    /// first: only that prompt's mark is made again.
    private func refreshMarks(_ items: [AgentItem]) {
        for index in sources.indices {
            let source = sources[index]
            let grew = source.reply.map { !source.saturated && Self.length(items[$0]) != source.length } ?? false
            let started = source.blanks.contains { Self.length(items[$0]) > 0 }
            guard grew || started else { continue }
            let mark = layout.marks[index]
            guard let promptPosition = layout.positions[mark.id] else { continue }
            let (fresh, freshSource) = TranscriptPromptMark.mark(at: promptPosition, in: items,
                                                                 position: mark.position, isShown: TranscriptTimeline.isShown)
            layout.marks[index] = fresh
            sources[index] = freshSource
        }
    }

    private static func isBlankThinking(_ item: AgentItem) -> Bool {
        guard case .thinking(let text) = item.kind else { return false }
        return text.isEmpty || text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    /// A reply's length in bytes: constant time, and it only grows.
    private static func length(_ item: AgentItem) -> Int {
        if case .text(let text) = item.kind { return text.utf8.count }
        return 0
    }
}

extension TranscriptTimeline {
    /// Thinking blocks arrive empty when the model keeps its reasoning to
    /// itself; there's nothing to expand. A queued follow-up waits under
    /// the composer instead.
    static func isShown(_ item: AgentItem) -> Bool {
        if item.queued { return false }
        if case .thinking(let text) = item.kind { return !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
        return true
    }

    /// How deep each item sits: 0 for the conversation's own, 1 for a
    /// subagent's, 2 for that subagent's own subagent's, and so on, by
    /// following each item's parent call up.
    static func depths(_ items: [AgentItem]) -> [String: Int] {
        let parents = Dictionary(items.map { ($0.id, $0.parent) }, uniquingKeysWith: { first, _ in first })
        var depths: [String: Int] = [:]
        for item in items where item.parent != nil {
            var depth = 0
            var parent = item.parent
            var seen = Set<String>()
            while let id = parent, seen.insert(id).inserted {
                depth += 1
                parent = parents[id] ?? nil
            }
            depths[item.id] = depth
        }
        return depths
    }

    /// How long each thinking block took, from the item after it, by id.
    /// Worked out in one pass: looking each one up was a scan per row.
    static func thinkingDurations(_ items: [AgentItem]) -> [String: TimeInterval] {
        var durations: [String: TimeInterval] = [:]
        for index in items.indices.dropLast() {
            guard case .thinking = items[index].kind, durations[items[index].id] == nil,
                  let duration = AgentElapsed.thinking(items[index], next: items[index + 1]) else { continue }
            durations[items[index].id] = duration
        }
        return durations
    }
}

/// One of your prompts on the transcript's rail.
struct TranscriptPromptMark: Identifiable, Equatable {
    let id: String
    let prompt: String
    /// The start of the agent's reply to it, when there's one yet.
    let reply: String?
    /// Where it sits in the transcript, 0 at the top and 1 at the end.
    let position: Double

    /// Where a mark's reply came from, to tell when streaming changed it.
    struct Source: Equatable {
        /// The reply's place, nil while there's none yet.
        var reply: Int?
        /// Its length in bytes when read.
        var length: Int
        /// It had more than the 2000 characters read, so more doesn't matter.
        var saturated: Bool
        /// Empty replies before it (or in the turn, when there's none yet):
        /// the first words into one of them make it the reply.
        var blanks: [Int]
    }

    /// Your prompts among `items` (the shown ones), each with the first
    /// words of the reply that followed it.
    static func marks(_ items: [AgentItem]) -> [TranscriptPromptMark] {
        marksWithSources(items).marks
    }

    static func marksWithSources(_ items: [AgentItem]) -> (marks: [TranscriptPromptMark], sources: [Source]) {
        guard items.count > 1 else { return ([], []) }
        var marks: [TranscriptPromptMark] = []
        var sources: [Source] = []
        for index in items.indices {
            guard case .user = items[index].kind else { continue }
            let (mark, source) = mark(at: index, in: items, position: Double(index) / Double(items.count - 1),
                                      isShown: { _ in true })
            marks.append(mark)
            sources.append(source)
        }
        return (marks, sources)
    }

    /// The mark for the prompt at `index`, reading its reply from the items
    /// after it up to the next prompt; items `isShown` turns down are passed
    /// over, so the whole conversation's items can be read in place.
    static func mark(at index: Int, in items: [AgentItem], position: Double,
                     isShown: (AgentItem) -> Bool) -> (TranscriptPromptMark, Source) {
        let item = items[index]
        let prompt: String
        if case .user(let text) = item.kind { prompt = text } else { prompt = "" }
        var source = Source(reply: nil, length: 0, saturated: false, blanks: [])
        var reply: String?
        for next in items.index(after: index) ..< items.endIndex where isShown(items[next]) {
            if case .user = items[next].kind { break }
            guard case .text(let text) = items[next].kind else { continue }
            if text.isEmpty { source.blanks.append(next); continue }
            // Only the reply's start is shown, so only its start is made
            // plain: the whole of a long reply was, on every streamed token.
            let start = text.prefix(2000)
            source.reply = next
            source.length = text.utf8.count
            source.saturated = start.endIndex != text.endIndex
            reply = String(MarkdownPlain.plain(String(start)).prefix(160))
            break
        }
        return (TranscriptPromptMark(id: item.id, prompt: prompt, reply: reply, position: position), source)
    }
}
