import AppKit
import SwiftUI

/// Find in a pane's retained output: the state behind the find bar drawn
/// over the terminal. It searches as you type, shows where the current
/// match is among all of them, scrolls the pane to it and boxes it there.
/// Searches start from the newest output, so Return (and ⌘G) carries on
/// upward to older matches and Shift-Return (⇧⌘G) comes back down.
@MainActor
final class OutputFindState: ObservableObject {
    enum Status: Equatable {
        case idle
        case searching
        case found(ordinal: Int, total: Int)
        case none
        case failed(String)
    }

    @Published private(set) var isOpen = false
    @Published var query = "" { didSet { if query != oldValue { scheduleSearch() } } }
    @Published var caseSensitive = false { didSet { if caseSensitive != oldValue { scheduleSearch() } } }
    @Published var regex = false { didSet { if regex != oldValue { scheduleSearch() } } }
    @Published private(set) var status: Status = .idle
    /// Bumped to put the cursor in the field, again if it is already open.
    @Published private(set) var focusRequest = 0
    /// Whether the matches come from the last thousand rows only, as a
    /// regular expression's do (see `OutputFind`).
    @Published private(set) var recentOnly = false
    private(set) var paneId: String?

    private let client: EngineClient
    /// Gives the keys back to the terminal when the bar closes.
    private let refocus: () -> Void
    private let queue = DispatchQueue(label: "com.jpxsoftware.octet.find", qos: .userInitiated)
    /// Bumped by every search and by closing, so a late answer is dropped.
    private var generation = 0
    private var pendingSearch: DispatchWorkItem?
    /// The server's last answer, which its next step searches on from.
    private var serverResult: TerminalSearchResult?
    /// Matches found here, with the one shown, for a local search.
    private var localMatches: [TerminalSearchMatch] = []
    private var localIndex: Int?

    /// Whether the session server is Octet's build, whose search takes
    /// case and regular-expression options.
    private let serverHasOptions: () -> Bool

    init(client: EngineClient, serverHasOptions: @escaping () -> Bool, refocus: @escaping () -> Void) {
        self.client = client
        self.serverHasOptions = serverHasOptions
        self.refocus = refocus
    }

    /// The menu's Find, Find Next and Find Previous, for `pane`.
    func perform(_ action: NSTextFinder.Action, pane: String?) {
        switch action {
        case .nextMatch: if isOpen { step(backward: true) }
        case .previousMatch: if isOpen { step(backward: false) }
        default: open(pane: pane)
        }
    }

    func open(pane: String?) {
        guard let pane else { return }
        let moved = paneId != pane
        paneId = pane
        if !isOpen {
            isOpen = true
            if query.isEmpty { query = NSPasteboard(name: .find).string(forType: .string) ?? "" }
        }
        focusRequest += 1
        if moved || status == .idle { scheduleSearch(delay: 0) }
    }

    func close() {
        guard isOpen else { return }
        isOpen = false
        generation += 1
        pendingSearch?.cancel()
        status = .idle
        serverResult = nil
        localMatches = []
        SearchHighlight.shared.box = nil
        refocus()
    }

    /// Up is older output, down newer.
    func step(backward: Bool) {
        guard isOpen, !query.isEmpty, let paneId else { return }
        if recentOnly {
            guard let index = OutputFind.step(from: localIndex, backward: backward, count: localMatches.count) else { return }
            localIndex = index
            status = .found(ordinal: index + 1, total: localMatches.count)
            reveal(localMatches[index], pane: paneId, generation: generation)
        } else {
            searchServer(backward: backward, from: serverResult)
        }
    }

    #if DEBUG
    /// Verification hook: types a query and finds it.
    func debugFind(_ text: String) { query = text }
    #endif

    // MARK: - Searching

    /// Typing waits a moment for the next key, so each one doesn't search.
    private func scheduleSearch(delay: TimeInterval = 0.18) {
        guard isOpen else { return }
        pendingSearch?.cancel()
        generation += 1
        serverResult = nil
        localMatches = []
        localIndex = nil
        guard !query.isEmpty else {
            status = .idle
            SearchHighlight.shared.box = nil
            return
        }
        let work = DispatchWorkItem { [weak self] in self?.startSearch() }
        pendingSearch = work
        DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: work)
    }

    private func startSearch() {
        guard isOpen, let paneId, !query.isEmpty else { return }
        let pasteboard = NSPasteboard(name: .find)
        pasteboard.clearContents()
        pasteboard.setString(query, forType: .string)
        recentOnly = OutputFind.searchesLocally(query: query, caseSensitive: caseSensitive, regex: regex,
                                                serverHasOptions: serverHasOptions())
        if recentOnly { searchLocally(pane: paneId) } else { searchServer(backward: true, from: nil) }
    }

    private func searchServer(backward: Bool, from prior: TerminalSearchResult?) {
        guard let paneId else { return }
        generation += 1
        let request = generation
        let client = client
        let options = OutputFind.serverParameters(query: query, caseSensitive: caseSensitive, regex: regex)
        let query = options["query"] as? String ?? query
        status = .searching
        queue.async { [weak self] in
            let outcome = Result { () -> (TerminalSearchResult, engineRows: Int?) in
                let found = try TerminalSearchResult.find(paneId: paneId, query: query, backward: backward, previous: prior) { method, params in
                    guard method == "pane.copy_search" else { return try client.call(method, params) }
                    return try client.call(method, params.merging(options) { _, option in option })
                }
                // The engine's rows run from the top of its own scrollback,
                // which can be longer than the pane terminal's.
                let scroll = (try? client.call("pane.get", ["pane_id": paneId]))
                    .flatMap { ($0["pane"] as? [String: Any])?["scroll"] as? [String: Any] }
                let rows = scroll.flatMap { scroll -> Int? in
                    guard let maximum = (scroll["max_offset_from_bottom"] as? NSNumber)?.intValue,
                          let viewport = (scroll["viewport_rows"] as? NSNumber)?.intValue else { return nil }
                    return maximum + viewport
                }
                return (found, rows)
            }
            DispatchQueue.main.async {
                guard let self, self.generation == request else { return }
                switch outcome {
                case .failure(let error): self.fail(error)
                case .success(let (found, engineRows)):
                    self.serverResult = found
                    guard let match = found.match else { return self.noMatches() }
                    self.status = .found(ordinal: found.ordinal ?? 1, total: found.total)
                    let terminal = PaneMirrorView.view(of: paneId)?.scroll
                    let shift = terminal.flatMap { scroll in
                        engineRows.map { scroll.maxOffsetFromBottom + scroll.viewportRows - $0 }
                    } ?? 0
                    self.reveal(match.shifted(by: shift), pane: paneId, generation: request)
                }
            }
        }
    }

    private func searchLocally(pane paneId: String) {
        generation += 1
        let request = generation
        let client = client, query = query, caseSensitive = caseSensitive, regex = regex
        // Rows are numbered in the pane's own terminal, whose bottom is the
        // engine's: the text read from the engine counts up from there.
        guard let view = PaneMirrorView.view(of: paneId)?.scroll.map({ (maximum: $0.maxOffsetFromBottom, rows: $0.viewportRows) }) else {
            return fail(EngineSocketError.malformedResponse("This pane has no scrollback viewport"))
        }
        status = .searching
        queue.async { [weak self] in
            let outcome = Result { () -> [TerminalSearchMatch] in
                let read = try client.call("pane.read", ["pane_id": paneId, "source": "recent",
                                                         "lines": OutputFind.readableRows])
                let text = (read["read"] as? [String: Any])?["text"] as? String ?? ""
                let rows = OutputFind.rows(of: text)
                return try OutputFind.matches(in: rows, firstRow: max(0, view.maximum + view.rows - rows.count),
                                              query: query, caseSensitive: caseSensitive, regex: regex)
            }
            DispatchQueue.main.async {
                guard let self, self.generation == request else { return }
                switch outcome {
                case .failure(let error): self.fail(error)
                case .success(let matches):
                    self.localMatches = matches
                    guard let index = OutputFind.step(from: nil, backward: true, count: matches.count) else {
                        return self.noMatches()
                    }
                    self.localIndex = index
                    self.status = .found(ordinal: index + 1, total: matches.count)
                    self.reveal(matches[index], pane: paneId, generation: request)
                }
            }
        }
    }

    /// Scrolls the pane's terminal so the match sits mid-view, and boxes it.
    /// The match's row counts down from the top of the engine's scrollback;
    /// the terminal's own lines up with it from the bottom. That can still
    /// be a few rows out (a replay drawn at another width wraps long lines
    /// differently), so once scrolled there the nearest occurrence among the
    /// terminal's own rows in view is the one boxed.
    private func reveal(_ estimate: TerminalSearchMatch, pane paneId: String, generation request: Int) {
        guard generation == request else { return }
        guard let view = PaneMirrorView.view(of: paneId), let scroll = view.scroll else {
            return fail(EngineSocketError.malformedResponse("This pane has no scrollback viewport"))
        }
        let maximum = scroll.maxOffsetFromBottom, viewportRows = scroll.viewportRows
        var match = estimate
        var offset = OutputFind.scrollOffset(for: match, maximum: maximum, viewportRows: viewportRows)
        view.scroll(toOffsetFromBottom: offset)
        if let rows = view.viewportRows(),
           let found = try? OutputFind.matches(in: rows, firstRow: maximum - offset, query: query,
                                               caseSensitive: caseSensitive, regex: regex),
           let nearest = found.min(by: { abs($0.start.row - estimate.start.row) < abs($1.start.row - estimate.start.row) }),
           nearest.start.row != estimate.start.row {
            match = nearest
            offset = OutputFind.scrollOffset(for: match, maximum: maximum, viewportRows: viewportRows)
            view.scroll(toOffsetFromBottom: offset)
        }
        SearchHighlight.shared.box = SearchHighlight.Box(
            paneId: paneId, row: match.start.row - (maximum - offset),
            startColumn: match.start.col, endColumn: match.end.row == match.start.row ? match.end.col : nil)
    }

    private func noMatches() {
        status = .none
        SearchHighlight.shared.box = nil
    }

    private func fail(_ error: Error) {
        status = .failed(OutputFind.describe(error))
        SearchHighlight.shared.box = nil
    }
}

/// The find bar over the terminal, in the same glass as the conversation's
/// (`TranscriptFindBar`): a field, "n of m", match case and regular
/// expression toggles, up and down, and close. Return and ↑ go to older
/// matches, Shift-Return and ↓ to newer ones, Escape closes.
struct OutputFindBar: View {
    @ObservedObject var find: OutputFindState

    var body: some View {
        HStack(spacing: Theme.Space.sm) {
            OctetTextField(placeholder: "Find in output", text: $find.query, label: "Find in terminal output",
                           invalid: isFailure, onSubmit: { find.step(backward: true) }, focusRequest: find.focusRequest)
                .frame(width: 200)
                .onKeyPress(.return, phases: .down) { press in
                    guard press.modifiers.contains(.shift) else { return .ignored }
                    find.step(backward: false)
                    return .handled
                }
                .onKeyPress(.upArrow) { find.step(backward: true); return .handled }
                .onKeyPress(.downArrow) { find.step(backward: false); return .handled }
            if !find.query.isEmpty {
                Text(statusText)
                    .font(Theme.Text.caption.monospacedDigit())
                    .foregroundStyle(statusColor)
                    .lineLimit(1)
                    .accessibilityLabel(accessibleStatus)
                if find.recentOnly {
                    OctetIcon("clock", size: 11)
                        .foregroundStyle(Theme.textTertiary)
                        .help("Searching the last \(OutputFind.readableRows.formatted()) lines")
                        .accessibilityLabel("Searching the last \(OutputFind.readableRows.formatted()) lines")
                }
            }
            OctetIconButton(icon: "search.case", help: "Match case", active: find.caseSensitive) {
                find.caseSensitive.toggle()
            }
            .accessibilityAddTraits(find.caseSensitive ? .isSelected : [])
            OctetIconButton(icon: "search.regex", help: "Regular expression", active: find.regex) {
                find.regex.toggle()
            }
            .accessibilityAddTraits(find.regex ? .isSelected : [])
            OctetIconButton(icon: "chevron.up", help: "Older match (Return)") { find.step(backward: true) }
                .disabled(!hasMatches)
            OctetIconButton(icon: "chevron.down", help: "Newer match (⇧Return)") { find.step(backward: false) }
                .disabled(!hasMatches)
            OctetIconButton(icon: "xmark", help: "Close (Esc)") { find.close() }
        }
        .padding(.horizontal, Theme.Space.md)
        .padding(.vertical, Theme.Space.sm)
        .octetGlass(cornerRadius: Theme.Radius.xl, fill: Theme.terminalBackground)
        .shadow(color: .black.opacity(0.3), radius: 8, y: 3)
        .onExitCommand { find.close() }
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Find in terminal output")
    }

    private var hasMatches: Bool {
        if case .found = find.status { return true }
        return false
    }

    private var isFailure: Bool {
        if case .failed = find.status { return true }
        return false
    }

    private var statusText: String {
        switch find.status {
        case .idle, .searching: "…"
        case .found(let ordinal, let total): "\(ordinal) of \(total)"
        case .none: "No matches"
        case .failed(let message): message
        }
    }

    private var accessibleStatus: String {
        switch find.status {
        case .idle, .searching: "Searching"
        case .found(let ordinal, let total): "Match \(ordinal) of \(total)"
        default: statusText
        }
    }

    private var statusColor: Color {
        switch find.status {
        case .none, .failed: Theme.danger
        default: Theme.textTertiary
        }
    }
}
