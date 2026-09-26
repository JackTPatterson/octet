import SwiftUI

/// What the agents changed in a project, file by file, with notes on lines
/// that go back to the agent as one message. Opened over the terminal from
/// the palette or ⌘⇧R; Esc closes it.
@MainActor
final class DiffReviewModel: ObservableObject {
    let directory: String
    @Published var base: ReviewDiff.Base = .uncommitted { didSet { if base != oldValue { refresh() } } }
    @Published private(set) var diff: ReviewDiff?
    @Published private(set) var loading = false
    @Published private(set) var notARepository = false
    @Published var selectedPath: String?
    @Published var comments: [ReviewComment] = []
    /// The line a note is being written on.
    @Published var drafting: (path: String, line: ReviewDiff.Line)?
    @Published var draft = ""
    @Published var commitMessage = ""
    @Published private(set) var committing = false
    private var timer: Timer?
    private var generation = 0

    init(directory: String) {
        self.directory = directory
    }

    var selectedFile: ReviewDiff.File? {
        diff?.files.first { $0.path == selectedPath } ?? diff?.files.first
    }

    func start() {
        refresh()
        // Agents keep working while it's open; follow along.
        timer?.invalidate()
        timer = Timer.scheduledTimer(withTimeInterval: 4, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.refresh(quietly: true) }
        }
    }

    func stop() {
        timer?.invalidate()
        timer = nil
    }

    func refresh(quietly: Bool = false) {
        generation += 1
        let generation = self.generation, directory = self.directory, base = self.base
        if !quietly { loading = true }
        DispatchQueue.global(qos: .userInitiated).async {
            let diff = ReviewDiff.read(in: directory, base: base)
            DispatchQueue.main.async {
                MainActor.assumeIsolated {
                    guard self.generation == generation else { return }
                    self.loading = false
                    self.notARepository = diff == nil
                    if diff != self.diff { self.diff = diff }
                    if let files = diff?.files, !files.contains(where: { $0.path == self.selectedPath }) {
                        self.selectedPath = files.first?.path
                    }
                }
            }
        }
    }

    func step(_ offset: Int) {
        guard let files = diff?.files, !files.isEmpty else { return }
        let index = files.firstIndex { $0.path == selectedFile?.path } ?? 0
        selectedPath = files[(index + offset + files.count) % files.count].path
    }

    func beginNote(on line: ReviewDiff.Line, in path: String) {
        drafting = (path, line)
        draft = comments.first { $0.path == path && $0.line == line }?.text ?? ""
    }

    func saveNote() {
        guard let (path, line) = drafting else { return }
        comments.removeAll { $0.path == path && $0.line == line }
        let text = draft.trimmingCharacters(in: .whitespacesAndNewlines)
        if !text.isEmpty { comments.append(ReviewComment(path: path, line: line, text: text)) }
        drafting = nil
        draft = ""
    }

    /// Commits every change shown, when the review is done.
    func commitAll() {
        let message = commitMessage, directory = self.directory
        committing = true
        DispatchQueue.global(qos: .userInitiated).async {
            let outcome = Result { try ReviewDiff.commitAll(message: message, in: directory) }
            DispatchQueue.main.async {
                MainActor.assumeIsolated {
                    self.committing = false
                    switch outcome {
                    case .success(let hash):
                        self.commitMessage = ""
                        ToastCenter.shared.succeed(nil, "Committed \(hash)", detail: message)
                        self.refresh()
                    case .failure(let error):
                        ToastCenter.shared.fail(nil, "Couldn't commit", detail: String(describing: error))
                    }
                }
            }
        }
    }

    func notes(on line: ReviewDiff.Line, in path: String) -> ReviewComment? {
        comments.first { $0.path == path && $0.line == line }
    }
}

struct DiffReviewView: View {
    @ObservedObject var model: DiffReviewModel
    @ObservedObject var store: SessionStore
    let close: () -> Void
    @State private var targetPane: String?
    /// Old and new side by side, rather than one column.
    @AppStorage("octet.review.split") private var split = false

    var body: some View {
        VStack(spacing: 0) {
            header
            Rectangle().fill(Theme.divider).frame(height: 1)
            if model.notARepository {
                message("Not a git repository", "Review shows changes in a repository's working tree.")
            } else if let diff = model.diff, diff.files.isEmpty {
                message("No changes", model.base == .uncommitted ? "Nothing differs from HEAD." : "Nothing differs from \(diff.baseName).")
            } else if model.diff != nil {
                HStack(spacing: 0) {
                    fileList.frame(width: 280)
                    Rectangle().fill(Theme.divider).frame(width: 1)
                    fileDiff.frame(maxWidth: .infinity, maxHeight: .infinity)
                }
            } else {
                message("Reading changes…", "")
            }
            Rectangle().fill(Theme.divider).frame(height: 1)
            footer
        }
        .background(Theme.terminalBackground)
        .onAppear { model.start() }
        .onDisappear { model.stop() }
        .onExitCommand {
            if model.drafting != nil { model.drafting = nil } else { close() }
        }
    }

    // MARK: - Header

    private var header: some View {
        HStack(spacing: 12) {
            VStack(alignment: .leading, spacing: 2) {
                Text("Review changes").font(.system(size: 15, weight: .semibold)).foregroundStyle(Theme.textPrimary)
                Text(subtitle).font(Theme.captionFont).foregroundStyle(Theme.textTertiary).lineLimit(1)
            }
            Spacer()
            Picker("Compare with", selection: $model.base) {
                Text("Uncommitted").tag(ReviewDiff.Base.uncommitted)
                Text("This branch").tag(ReviewDiff.Base.branch)
            }
            .pickerStyle(.segmented).labelsHidden().frame(width: 220)
            .help("Uncommitted: against HEAD. This branch: everything since it left the default branch.")
            Picker("Layout", selection: $split) {
                Image(systemName: "rectangle").tag(false).help("One column")
                Image(systemName: "rectangle.split.2x1").tag(true).help("Side by side")
            }
            .pickerStyle(.segmented).labelsHidden().frame(width: 76)
            .help("One column, or old and new side by side")
            OctetButton(title: "Previous", icon: "arrow.up", kind: .ghost, compact: true) { model.step(-1) }
                .keyboardShortcut(.upArrow, modifiers: .option)
                .help("Previous file (⌥↑)")
            OctetButton(title: "Next", icon: "arrow.down", kind: .ghost, compact: true) { model.step(1) }
                .keyboardShortcut(.downArrow, modifiers: .option)
                .help("Next file (⌥↓)")
            OctetButton(title: "Refresh", icon: "arrow.clockwise", kind: .ghost, compact: true) { model.refresh() }
            OctetButton(title: "Close", kind: .ghost, compact: true, action: close).help("Back (Esc)")
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
    }

    private var subtitle: String {
        let project = URL(fileURLWithPath: model.directory).lastPathComponent
        guard let diff = model.diff else { return project }
        let files = diff.files.count
        return "\(project) · \(files) \(files == 1 ? "file" : "files") · +\(diff.added) −\(diff.removed) against \(diff.baseName)"
    }

    // MARK: - Files

    private var fileList: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 1) {
                ForEach(model.diff?.files ?? []) { file in
                    let selected = file.path == model.selectedFile?.path
                    let notes = model.comments.filter { $0.path == file.path }.count
                    Button { model.selectedPath = file.path } label: {
                        HStack(spacing: 7) {
                            Text(statusMark(file.status))
                                .font(Theme.monoFont.weight(.semibold))
                                .foregroundStyle(statusColor(file.status))
                                .frame(width: 12)
                            VStack(alignment: .leading, spacing: 1) {
                                Text((file.path as NSString).lastPathComponent)
                                    .font(Theme.uiFont).foregroundStyle(selected ? Theme.textPrimary : Theme.textSecondary)
                                    .lineLimit(1)
                                let folder = (file.path as NSString).deletingLastPathComponent
                                if !folder.isEmpty {
                                    Text(folder).font(Theme.captionFont).foregroundStyle(Theme.textTertiary)
                                        .lineLimit(1).truncationMode(.head)
                                }
                            }
                            Spacer(minLength: 4)
                            if notes > 0 {
                                Text("\(notes)").font(Theme.captionFont.weight(.semibold)).foregroundStyle(Theme.onAccent)
                                    .padding(.horizontal, 5).background(Capsule().fill(Theme.accent))
                            }
                            Text(file.binary ? "bin" : "+\(file.added) −\(file.removed)")
                                .font(Theme.captionFont.monospacedDigit()).foregroundStyle(Theme.textTertiary)
                        }
                        .padding(.horizontal, 10).padding(.vertical, 6)
                        .background(selected ? Theme.cardSelected : Color.clear)
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(.vertical, 6)
        }
        .octetScrollIndicators()
    }

    private func statusMark(_ status: ReviewDiff.File.Status) -> String {
        switch status {
        case .added: "A"
        case .deleted: "D"
        case .modified: "M"
        }
    }

    private func statusColor(_ status: ReviewDiff.File.Status) -> Color {
        switch status {
        case .added: Self.addedColor
        case .deleted: Theme.danger
        case .modified: Theme.textSecondary
        }
    }

    static var addedColor: Color { Color(hex: TerminalTheme.named(SettingsStore.shared.values.themeName).ansi[2]) }

    // MARK: - Diff

    @ViewBuilder
    private var fileDiff: some View {
        if let file = model.selectedFile {
            if file.binary {
                message("Binary file", "\(file.path) changed; there's no text to show.")
            } else if file.tooLarge {
                message("Too large to show", "\(file.path): +\(file.added) −\(file.removed). Open it in an editor to review.")
            } else {
                let colored = Self.colors(file)
                GeometryReader { proxy in
                ScrollView([.vertical, .horizontal]) {
                    LazyVStack(alignment: .leading, spacing: 0) {
                        ForEach(Array(file.hunks.enumerated()), id: \.offset) { _, hunk in
                            Text(hunk.header)
                                .font(Theme.monoFont).foregroundStyle(Theme.textTertiary)
                                .padding(.horizontal, 12).padding(.vertical, 5)
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .background(Theme.card)
                            if split {
                                ForEach(hunk.pairs) { pair in
                                    DiffSplitRow(pair: pair, path: file.path, colored: colored,
                                                 half: max(200, proxy.size.width / 2), model: model)
                                }
                            } else {
                                ForEach(hunk.lines) { line in
                                    DiffReviewLine(line: line, path: file.path, text: colored[line.index], model: model)
                                }
                            }
                        }
                    }
                    .padding(.bottom, 20)
                    // Rows span the pane however short their text, so a line's
                    // tint reads as the whole line.
                    .frame(minWidth: proxy.size.width, alignment: .leading)
                }
                .id(file.path)
                .octetScrollIndicators()
                }
            }
        }
    }

    /// Syntax colours for a file's lines, by index; each hunk starts fresh,
    /// since it may begin inside anything.
    static func colors(_ file: ReviewDiff.File) -> [Int: AttributedString] {
        var result: [Int: AttributedString] = [:]
        for hunk in file.hunks {
            var state = CodeHighlighter.State()
            for line in hunk.lines { result[line.index] = CodeColors.attributed(line.text, state: &state) }
        }
        return result
    }

    private func message(_ title: String, _ detail: String) -> some View {
        VStack(spacing: 6) {
            Text(title).font(Theme.uiFontMedium).foregroundStyle(Theme.textSecondary)
            if !detail.isEmpty { Text(detail).font(Theme.captionFont).foregroundStyle(Theme.textTertiary) }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    // MARK: - Sending

    /// Agents working in this project, the one in front first.
    private var agents: [EngineAgent] {
        let top = AccountProfiles.projectRoot(of: model.directory) ?? model.directory
        return store.snapshot.agents.filter { agent in
            guard agent.agent != nil, !agent.isSubagentViewer, let cwd = agent.effectiveCwd else { return false }
            return AccountProfiles.contains(top, cwd) || AccountProfiles.projectRoot(of: cwd) == top
        }
    }

    private func name(_ agent: EngineAgent) -> String {
        let brand = AgentBrand.forAgent(agent.agent)?.displayName ?? agent.agent ?? "Agent"
        let tab = agent.tabId.flatMap { id in store.snapshot.tabs.first { $0.tabId == id } }
            .map { TabAutoName.display(label: $0.label, number: $0.number) }
        return tab.map { "\(brand) in \($0)" } ?? brand
    }

    private var footer: some View {
        let count = model.comments.count
        let candidates = agents
        let target = candidates.first { $0.paneId == targetPane } ?? candidates.first
        return HStack(spacing: 10) {
            Text(count == 0 ? "Click a line to leave a note for the agent." : "\(count) \(count == 1 ? "note" : "notes")")
                .font(Theme.captionFont).foregroundStyle(Theme.textTertiary)
            if count > 0 {
                OctetButton(title: "Clear", kind: .ghost, compact: true) { model.comments = [] }
            }
            Spacer()
            // Done reviewing: commit what's here.
            if count == 0, model.diff.map({ !$0.files.isEmpty }) == true {
                OctetTextField(placeholder: "Commit message", text: $model.commitMessage) { model.commitAll() }
                    .frame(width: 280)
                OctetButton(title: model.committing ? "Committing…" : "Commit All", kind: .secondary, compact: true) {
                    model.commitAll()
                }
                .disabled(model.committing || model.commitMessage.trimmingCharacters(in: .whitespaces).isEmpty)
                .help("Stage every change shown and commit it")
            }
            if candidates.count > 1 {
                Picker("Send to", selection: Binding(get: { target?.paneId }, set: { targetPane = $0 })) {
                    ForEach(candidates) { agent in Text(name(agent)).tag(Optional(agent.paneId)) }
                }
                .labelsHidden().frame(width: 220)
            }
            OctetButton(title: target.map { "Send to \(name($0))" } ?? "No agent in this project",
                        kind: target == nil ? .secondary : .primary, compact: true) {
                guard let target else { return }
                send(to: target)
            }
            .disabled(count == 0 || target == nil)
            .keyboardShortcut(.return, modifiers: .command)
            .help("Send the notes as one message (⌘↩)")
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 8)
    }

    private func send(to agent: EngineAgent) {
        let prompt = ReviewComment.prompt(model.comments)
        guard !prompt.isEmpty else { return }
        store.broadcast(prompt, to: [Broadcast.Target(paneId: agent.paneId, name: name(agent), isAgent: true)])
        model.comments = []
    }
}

/// One line of the diff: numbers, the text, and its note. Click to write one.
private struct DiffReviewLine: View {
    let line: ReviewDiff.Line
    let path: String
    var text: AttributedString?
    @ObservedObject var model: DiffReviewModel
    @State private var hovered = false

    var body: some View {
        let note = model.notes(on: line, in: path)
        let drafting = model.drafting.map { $0.path == path && $0.line == line } ?? false
        VStack(alignment: .leading, spacing: 0) {
            Button { model.beginNote(on: line, in: path) } label: {
                HStack(spacing: 0) {
                    number(line.oldNumber)
                    number(line.newNumber)
                    Text(marker).frame(width: 16).foregroundStyle(tint)
                    Group {
                        if let text { Text(text) } else { Text(line.text.isEmpty ? " " : line.text) }
                    }
                    .opacity(line.kind == .context ? 0.8 : 1)
                    .fixedSize(horizontal: true, vertical: false)
                    Spacer(minLength: 0)
                }
                .font(Theme.monoFont)
                .padding(.vertical, 1)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(background)
                .overlay(alignment: .leading) {
                    if hovered && note == nil && !drafting {
                        Image(systemName: "plus.bubble.fill")
                            .font(.system(size: 11)).foregroundStyle(Theme.accent)
                            .padding(.leading, 4)
                    }
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .onHover { hovered = $0 }
            .help("Leave a note on this line")
            DiffNoteArea(line: line, path: path, model: model)
        }
    }

    private func number(_ value: Int?) -> some View {
        Text(value.map(String.init) ?? "")
            .foregroundStyle(Theme.textTertiary)
            .frame(width: 42, alignment: .trailing)
            .padding(.trailing, 6)
    }

    private var marker: String {
        switch line.kind {
        case .added: "+"
        case .removed: "−"
        case .context: " "
        }
    }

    private var tint: Color {
        switch line.kind {
        case .added: DiffReviewView.addedColor
        case .removed: Theme.danger
        case .context: Theme.textTertiary
        }
    }

    private var background: Color {
        switch line.kind {
        case .added: DiffReviewView.addedColor.opacity(0.12)
        case .removed: Theme.danger.opacity(0.12)
        case .context: hovered ? Theme.hover : .clear
        }
    }
}

/// A line's note under it, or the editor while one is being written.
private struct DiffNoteArea: View {
    let line: ReviewDiff.Line
    let path: String
    @ObservedObject var model: DiffReviewModel

    var body: some View {
        let note = model.notes(on: line, in: path)
        let drafting = model.drafting.map { $0.path == path && $0.line == line } ?? false
        if drafting {
            noteEditor
        } else if let note {
            Button { model.beginNote(on: line, in: path) } label: {
                HStack(alignment: .top, spacing: 8) {
                    Image(systemName: "text.bubble.fill").foregroundStyle(Theme.accent)
                    Text(note.text).foregroundStyle(Theme.textPrimary).fixedSize(horizontal: false, vertical: true)
                    Spacer()
                }
                .font(Theme.uiFont)
                .padding(8)
                .frame(maxWidth: 640, alignment: .leading)
                .background(RoundedRectangle(cornerRadius: 6).fill(Theme.card))
                .overlay(RoundedRectangle(cornerRadius: 6).strokeBorder(Theme.border, lineWidth: 1))
            }
            .buttonStyle(.plain)
            .padding(.leading, 100).padding(.vertical, 4)
        }
    }

    private var noteEditor: some View {
        VStack(alignment: .trailing, spacing: 6) {
            TextField("What should the agent change here?", text: $model.draft, axis: .vertical)
                .textFieldStyle(.plain)
                .font(Theme.uiFont)
                .lineLimit(2...8)
                .padding(8)
                .background(RoundedRectangle(cornerRadius: 6).fill(Theme.card))
                .overlay(RoundedRectangle(cornerRadius: 6).strokeBorder(Theme.accent, lineWidth: 1))
                .onSubmit { model.saveNote() }
            HStack(spacing: 6) {
                OctetButton(title: "Cancel", kind: .ghost, compact: true) { model.drafting = nil }
                OctetButton(title: "Save note", kind: .primary, compact: true) { model.saveNote() }
            }
        }
        .frame(maxWidth: 640)
        .padding(.leading, 100).padding(.vertical, 6)
    }
}

/// Old and new lines side by side; either side takes a note.
private struct DiffSplitRow: View {
    let pair: ReviewDiff.Hunk.Pair
    let path: String
    let colored: [Int: AttributedString]
    let half: CGFloat
    @ObservedObject var model: DiffReviewModel

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 0) {
                side(pair.left, number: pair.left?.oldNumber)
                Rectangle().fill(Theme.divider).frame(width: 1)
                side(pair.right, number: pair.right?.newNumber)
            }
            .font(Theme.monoFont)
            // A context line is the same on both sides: one note.
            ForEach(pair.left == pair.right ? [pair.left].compactMap { $0 } : [pair.left, pair.right].compactMap { $0 }) { line in
                DiffNoteArea(line: line, path: path, model: model)
            }
        }
    }

    private func side(_ line: ReviewDiff.Line?, number: Int?) -> some View {
        Button { if let line { model.beginNote(on: line, in: path) } } label: {
            HStack(spacing: 0) {
                Text(number.map(String.init) ?? "")
                    .foregroundStyle(Theme.textTertiary)
                    .frame(width: 42, alignment: .trailing)
                    .padding(.trailing, 8)
                Group {
                    if let line, let text = colored[line.index] { Text(text) } else { Text(line?.text ?? " ") }
                }
                .opacity(line?.kind == .context ? 0.8 : 1)
                .lineLimit(1)
                Spacer(minLength: 0)
            }
            .padding(.vertical, 1)
            .frame(width: half - 1, alignment: .leading)
            .clipped()
            .background(background(line))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(line == nil)
        .help(line == nil ? "" : "Leave a note on this line")
    }

    private func background(_ line: ReviewDiff.Line?) -> Color {
        switch line?.kind {
        case .added: DiffReviewView.addedColor.opacity(0.12)
        case .removed: Theme.danger.opacity(0.12)
        case .context: .clear
        case nil: Theme.card.opacity(0.5)
        }
    }
}
