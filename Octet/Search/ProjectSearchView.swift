import AppKit
import SwiftUI

/// Which window has Search in Project open, and its search. One at a time:
/// opening it in another window moves it there.
@MainActor
final class ProjectSearchCenter: ObservableObject {
    static let shared = ProjectSearchCenter()

    @Published private(set) var model: ProjectSearchModel?
    private(set) var windowId: WindowContext.ID?

    func isShowing(in window: WindowContext) -> Bool { model != nil && windowId == window.id }

    /// Opens it on the focused workspace's project, or says there's none.
    /// `root` searches that folder instead (the debug hook's override).
    func open(in window: WindowContext, query: String? = nil, root: String? = nil) {
        guard let directory = root ?? window.focusedWorkspace.flatMap({ window.store.snapshot.directory(ofWorkspace: $0.workspaceId) })
                ?? window.editor.activeDocument?.directory else {
            ToastCenter.shared.info("Open a project to search its files")
            return
        }
        let root = ProjectSearchRunner.searchRoot(for: directory)
        if model?.root != root || windowId != window.id {
            model?.cancel()
            model = ProjectSearchModel(root: root)
        }
        windowId = window.id
        if let query { model?.query = query }
        DebugSnapshot.overlay("project-search", true)
    }

    func toggle(in window: WindowContext) {
        isShowing(in: window) ? close() : open(in: window)
    }

    /// Hides it, keeping the search for next time in the same project.
    func close() {
        guard model != nil else { return }
        model?.cancel()
        windowId = nil
        objectWillChange.send()
        DebugSnapshot.overlay("project-search", false)
        OctetTerminalRuntime.focusTerminal()
    }
}

/// One search: the query and its options, the matches found so far.
@MainActor
final class ProjectSearchModel: ObservableObject {
    let root: String
    @Published var query = "" { didSet { if query != oldValue { schedule() } } }
    @Published var caseSensitive = false { didSet { if caseSensitive != oldValue { schedule(debounce: false) } } }
    @Published var wholeWord = false { didSet { if wholeWord != oldValue { schedule(debounce: false) } } }
    @Published var regex = false { didSet { if regex != oldValue { schedule(debounce: false) } } }
    @Published var include = "" { didSet { if include != oldValue { schedule() } } }
    @Published var showsInclude = false
    @Published private(set) var matches: [ProjectSearchMatch] = []
    @Published private(set) var groups: [ProjectSearchGroups.Group] = []
    @Published private(set) var searching = false
    @Published private(set) var truncated = false
    @Published private(set) var error: String?
    @Published private(set) var engine: ProjectSearchRunner.Engine?
    @Published var selection = 0

    private var task: Task<Void, Never>?
    private var generation = 0
    /// Results of the search before stay up until the new one finds its
    /// first batch, so the list doesn't flash empty on every keystroke.
    private var replaceOnNext = false

    init(root: String) { self.root = root }

    var options: ProjectSearchOptions {
        ProjectSearchOptions(query: query, caseSensitive: caseSensitive, wholeWord: wholeWord, regex: regex,
                             include: include)
    }

    var projectName: String { (root as NSString).lastPathComponent }
    var fileCount: Int { groups.count }

    func cancel() {
        task?.cancel()
        task = nil
        searching = false
    }

    /// Starts the search again for what's typed now, after a short pause
    /// while typing.
    func schedule(debounce: Bool = true) {
        task?.cancel()
        generation += 1
        let generation = generation
        let options = options
        error = nil
        guard !options.query.isEmpty else {
            set([])
            truncated = false
            searching = false
            return
        }
        searching = true
        replaceOnNext = true
        let root = root
        task = Task { [weak self] in
            if debounce { try? await Task.sleep(for: .milliseconds(180)) }
            guard !Task.isCancelled else { return }
            do {
                let outcome = try await ProjectSearchRunner.run(options, in: root) { [weak self] batch in
                    await self?.receive(batch, generation: generation)
                }
                guard let self, self.generation == generation, !Task.isCancelled else { return }
                if self.replaceOnNext { self.set([]) }
                self.truncated = outcome.truncated
                self.engine = outcome.engine
                self.searching = false
            } catch {
                guard let self, self.generation == generation, !Task.isCancelled else { return }
                self.set([])
                self.searching = false
                switch error {
                case ProjectSearchRunner.Failure.invalidPattern: self.error = "Invalid regular expression"
                case ProjectSearchRunner.Failure.failed(let message): self.error = message
                default: if !(error is CancellationError) { self.error = error.localizedDescription }
                }
            }
        }
    }

    private func receive(_ batch: [ProjectSearchMatch], generation: Int) {
        guard generation == self.generation else { return }
        if replaceOnNext {
            replaceOnNext = false
            selection = 0
            set(batch)
        } else {
            set(matches + batch)
        }
    }

    private func set(_ matches: [ProjectSearchMatch]) {
        self.matches = matches
        groups = ProjectSearchGroups.group(matches)
        selection = min(selection, max(0, matches.count - 1))
    }

    func move(_ delta: Int) {
        guard !matches.isEmpty else { return }
        selection = (selection + delta + matches.count) % matches.count
    }

    var selected: ProjectSearchMatch? { matches.indices.contains(selection) ? matches[selection] : nil }
}

/// Draws Search in Project in the window it's open in.
struct ProjectSearchHost: View {
    @ObservedObject var center = ProjectSearchCenter.shared
    @EnvironmentObject private var window: WindowContext
    @ObservedObject private var motion = MotionPreferences.shared

    var body: some View {
        ZStack {
            if center.isShowing(in: window), let model = center.model {
                ProjectSearchDialog(model: model, onClose: { center.close() }) { match in
                    center.close()
                    window.openFile(atMatch: match, in: model.root)
                }
                .transition(motion.animates(.palette)
                    ? .opacity.combined(with: .scale(scale: 0.97, anchor: .top))
                    : .identity)
            }
        }
        .animation(motion.animation(.palette, .smooth(duration: 0.16)), value: center.isShowing(in: window))
    }
}

/// Search in Project, after T3 Code's ProjectContentSearchDialog: a field
/// with case, whole-word and regex toggles, a files filter, and matches
/// grouped by file with what matched highlighted. ↑↓ move, Return opens the
/// file at that line.
struct ProjectSearchDialog: View {
    @ObservedObject var model: ProjectSearchModel
    let onClose: () -> Void
    let onOpen: (ProjectSearchMatch) -> Void
    @FocusState private var fieldFocused: Bool
    @ObservedObject private var motion = MotionPreferences.shared

    var body: some View {
        ZStack(alignment: .top) {
            Color.black.opacity(0.35)
                .ignoresSafeArea()
                .onTapGesture(perform: onClose)
            VStack(spacing: 0) {
                searchRow
                if model.showsInclude { includeRow }
                Rectangle().fill(Theme.divider).frame(height: 1)
                status
                results
                footer
            }
            .frame(width: 720)
            .octetGlass(cornerRadius: 18)
            .padding(.top, 64)
        }
        .onAppear { DispatchQueue.main.async { fieldFocused = true } }
    }

    // MARK: Field

    private var searchRow: some View {
        HStack(spacing: 10) {
            OctetIcon("magnifyingglass", size: 19)
                .foregroundStyle(Theme.textSecondary)
            TextField("Search in \(model.projectName)", text: $model.query)
                .textFieldStyle(.plain)
                .font(.system(size: 15))
                .foregroundStyle(Theme.textPrimary)
                .focused($fieldFocused)
                .onKeyPress(.upArrow) { model.move(-1); return .handled }
                .onKeyPress(.downArrow) { model.move(1); return .handled }
                .onKeyPress(keys: [.init("p"), .init("k")], phases: .down) { press in
                    guard press.modifiers.contains(.control) else { return .ignored }
                    model.move(-1)
                    return .handled
                }
                .onKeyPress(keys: [.init("n"), .init("j")], phases: .down) { press in
                    guard press.modifiers.contains(.control) else { return .ignored }
                    model.move(1)
                    return .handled
                }
                // VS Code's keys for the toggles: ⌥⌘C, ⌥⌘W, ⌥⌘R.
                .onKeyPress(keys: [.init("c"), .init("w"), .init("r")], phases: .down) { press in
                    guard press.modifiers.contains(.option), press.modifiers.contains(.command) else { return .ignored }
                    switch press.key.character {
                    case "c": model.caseSensitive.toggle()
                    case "w": model.wholeWord.toggle()
                    default: model.regex.toggle()
                    }
                    return .handled
                }
                .onKeyPress(.escape) { onClose(); return .handled }
                .onSubmit(openSelection)
            toggles
        }
        .padding(.leading, 16)
        .padding(.trailing, 10)
        .frame(height: 50)
    }

    private var toggles: some View {
        HStack(spacing: 2) {
            OctetIconButton(icon: "search.case", help: "Match Case (⌥⌘C)", active: model.caseSensitive) {
                model.caseSensitive.toggle()
            }
            OctetIconButton(icon: "search.word", help: "Match Whole Word (⌥⌘W)", active: model.wholeWord) {
                model.wholeWord.toggle()
            }
            OctetIconButton(icon: "search.regex", help: "Use Regular Expression (⌥⌘R)", active: model.regex) {
                model.regex.toggle()
            }
            Rectangle().fill(Theme.divider).frame(width: 1, height: 16).padding(.horizontal, 3)
            OctetIconButton(icon: "search.filter", help: "Files to Include",
                            active: model.showsInclude || !model.include.isEmpty) {
                model.showsInclude.toggle()
                if !model.showsInclude { fieldFocused = true }
            }
        }
        .padding(2)
        .background(RoundedRectangle(cornerRadius: Theme.popoverRadius).fill(Theme.card.opacity(0.6)))
    }

    private var includeRow: some View {
        HStack(spacing: 8) {
            Text("Files")
                .font(Theme.uiFontMedium)
                .foregroundStyle(Theme.textTertiary)
                .frame(width: 34, alignment: .leading)
            OctetTextField(placeholder: "e.g. *.swift, src/**, !*Tests*", text: $model.include,
                           label: "Files to include") { fieldFocused = true }
        }
        .padding(.horizontal, 16)
        .padding(.bottom, 10)
    }

    // MARK: Results

    @ViewBuilder
    private var status: some View {
        if !model.query.isEmpty {
            HStack(spacing: 8) {
                if model.searching {
                    LoadingLine(width: 18)
                    Text("Searching…")
                } else if let error = model.error {
                    Text(error).foregroundStyle(Theme.danger)
                } else {
                    Text(summary)
                }
                Spacer()
                if let engine = model.engine, !model.searching, model.error == nil {
                    Text(engine.rawValue).foregroundStyle(Theme.textMuted)
                }
            }
            .font(Theme.captionFont)
            .foregroundStyle(Theme.textTertiary)
            .padding(.horizontal, 16)
            .frame(height: 28)
            .overlay(alignment: .bottom) { Rectangle().fill(Theme.divider).frame(height: 1) }
        }
    }

    private var summary: String {
        let count = model.matches.count
        let files = model.fileCount
        return "\(count.formatted())\(model.truncated ? "+" : "") result\(count == 1 ? "" : "s") in \(files.formatted()) file\(files == 1 ? "" : "s")"
    }

    private var results: some View {
        ScrollViewReader { proxy in
            ScrollView {
                if model.matches.isEmpty {
                    Text(emptyText)
                        .font(Theme.uiFont)
                        .foregroundStyle(Theme.textTertiary)
                        .frame(maxWidth: .infinity, alignment: .center)
                        .padding(.vertical, 40)
                } else {
                    LazyVStack(alignment: .leading, spacing: 0, pinnedViews: [.sectionHeaders]) {
                        ForEach(model.groups) { group in
                            Section {
                                ForEach(group.matches, id: \.index) { entry in
                                    ProjectSearchRow(match: entry.match, selected: entry.index == model.selection)
                                        .id(entry.index)
                                        .contentShape(Rectangle())
                                        .onTapGesture {
                                            model.selection = entry.index
                                            openSelection()
                                        }
                                }
                            } header: {
                                fileHeader(group)
                            }
                        }
                    }
                    .padding(.bottom, 6)
                }
            }
            .frame(height: 420)
            .onChange(of: model.selection) { _, index in
                proxy.scrollTo(index)
            }
        }
    }

    private var emptyText: String {
        if model.query.isEmpty { return "Type to search the files in \(model.projectName)." }
        if model.searching { return "" }
        if model.error != nil { return "" }
        return "No results found."
    }

    private func fileHeader(_ group: ProjectSearchGroups.Group) -> some View {
        let first = group.matches.first?.match
        return HStack(spacing: 6) {
            if let logo = LanguageLogo(language: (group.path as NSString).pathExtension, size: 13) {
                logo
            } else {
                OctetIcon("tool.read", size: 13).foregroundStyle(Theme.textTertiary)
            }
            Text(first?.fileName ?? group.path)
                .font(Theme.uiFontMedium)
                .foregroundStyle(Theme.textPrimary)
            if let directory = first?.directory, !directory.isEmpty {
                Text(directory)
                    .font(Theme.captionFont)
                    .foregroundStyle(Theme.textTertiary)
                    .lineLimit(1)
                    .truncationMode(.head)
            }
            Spacer(minLength: 8)
            Text(verbatim: String(group.matches.count))
                .font(.system(size: 10, weight: .medium).monospacedDigit())
                .foregroundStyle(Theme.textTertiary)
                .padding(.horizontal, 6)
                .frame(height: 16)
                .background(Capsule().fill(Theme.card))
        }
        .padding(.horizontal, 14)
        .frame(height: 30)
        .background(Theme.sidebar.opacity(0.96))
    }

    private var footer: some View {
        HStack(spacing: 14) {
            hint("↑↓", "navigate")
            hint("↩", "open file")
            hint("esc", "close")
            Spacer()
            Text((model.root as NSString).abbreviatingWithTildeInPath)
                .font(.system(size: 10.5))
                .foregroundStyle(Theme.textMuted)
                .lineLimit(1)
                .truncationMode(.head)
        }
        .padding(.horizontal, 14)
        .frame(height: 30)
        .background(Theme.chrome)
        .overlay(alignment: .top) { Rectangle().fill(Theme.divider).frame(height: 1) }
    }

    private func hint(_ key: String, _ label: String) -> some View {
        HStack(spacing: 4) {
            Keycap(text: key)
            Text(label).font(.system(size: 10.5)).foregroundStyle(Theme.textTertiary)
        }
    }

    private func openSelection() {
        guard let match = model.selected else { return }
        onOpen(match)
    }
}

/// A matching line: its number, then the line with each match marked.
private struct ProjectSearchRow: View {
    let match: ProjectSearchMatch
    let selected: Bool
    @State private var hovered = false

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 10) {
            Text(verbatim: String(match.line))
                .font(.system(size: 11, design: .monospaced))
                .foregroundStyle(Theme.textMuted)
                .frame(width: 40, alignment: .trailing)
            Text(highlighted)
                .font(.system(size: 11.5, design: .monospaced))
                .lineLimit(1)
                .truncationMode(.tail)
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 8)
        .frame(height: 24)
        .background(RoundedRectangle(cornerRadius: Theme.controlRadius)
            .fill(selected ? Theme.cardSelected : hovered ? Theme.hover : .clear))
        .padding(.horizontal, 6)
        .onHover { hovered = $0 }
    }

    private var highlighted: AttributedString {
        let preview = ProjectSearchHighlight.preview(match.text, ranges: match.ranges)
        var text = AttributedString()
        for segment in ProjectSearchHighlight.segments(preview.text, ranges: preview.ranges) {
            var piece = AttributedString(segment.text)
            if segment.isMatch {
                piece.foregroundColor = Theme.textPrimary
                piece.backgroundColor = Theme.accent.opacity(0.32)
            } else {
                piece.foregroundColor = selected ? Theme.textSecondary : Theme.textTertiary
            }
            text += piece
        }
        return text
    }
}

// MARK: - Opening a match

extension WindowContext {
    /// Opens the file a search matched in the editor, with the match
    /// selected and scrolled to once the file's text is showing.
    func openFile(atMatch match: ProjectSearchMatch, in root: String) {
        let url = URL(fileURLWithPath: root).appendingPathComponent(match.path)
        openFile(url, presentation: .split)
        let range = match.ranges.first
        editor.revealWhenShowing(url, line: match.line, columns: range)
    }
}

extension EditorWorkspace {
    /// Selects `columns` (UTF-16 offsets) on a 1-based `line` of `url`, or the
    /// whole line, once the editor shows that file: right after opening it
    /// may still hold the file that was in front.
    func revealWhenShowing(_ url: URL, line: Int, columns: Range<Int>?, attempts: Int = 20) {
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) { [weak self] in
            guard let self else { return }
            let showing = self.activeDocument.map { $0.url == url.standardizedFileURL.resolvingSymlinksInPath() } ?? false
            guard let textView = self.textView, let document = self.activeDocument, showing,
                  textView.string == document.text || attempts == 0 else {
                if attempts > 0 { self.revealWhenShowing(url, line: line, columns: columns, attempts: attempts - 1) }
                return
            }
            let text = textView.string as NSString
            let lineRange = EditorLines.range(ofLine: line, in: text)
            var selection = lineRange
            if let columns {
                let contentLength = max(0, lineRange.length - (text.substring(with: lineRange).hasSuffix("\n") ? 1 : 0))
                let start = min(columns.lowerBound, contentLength)
                let end = min(columns.upperBound, contentLength)
                if end > start { selection = NSRange(location: lineRange.location + start, length: end - start) }
            }
            textView.setSelectedRange(selection)
            textView.scrollRangeToVisible(selection)
            textView.showFindIndicator(for: selection)
            self.focusEditor()
        }
    }
}

enum EditorLines {
    /// The range of a 1-based line, its line break included; the last line
    /// when there are fewer.
    static func range(ofLine line: Int, in text: NSString) -> NSRange {
        var location = 0
        for _ in 1..<max(1, line) {
            let next = text.range(of: "\n", range: NSRange(location: location, length: text.length - location))
            guard next.location != NSNotFound else { break }
            location = next.location + 1
        }
        return text.lineRange(for: NSRange(location: min(location, text.length), length: 0))
    }
}

// MARK: - Palette

@MainActor
enum ProjectSearchPalette {
    static func items(window: WindowContext) -> [PaletteItem] {
        [PaletteItem(
            id: "action.searchInProject", kind: .action, title: "Search in Project…",
            subtitle: "Find text in the files of this workspace's project",
            keywords: ["find", "grep", "ripgrep", "contents", "text", "files", "search"],
            shortcut: OctetShortcut.searchInProject.keys, icon: .symbol("magnifyingglass"),
            effect: .run { DispatchQueue.main.async { ProjectSearchCenter.shared.open(in: window) } }
        )]
    }
}
