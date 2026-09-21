import AppKit
import Foundation

/// Octet's own command line: while a pane sits at a bare
/// shell prompt, Octet takes the keystrokes, draws and edits the line itself
/// — highlighted, with a suggestion from history — and hands the finished
/// command to the shell on Return. Anything Octet doesn't handle flushes what
/// was typed into the pane and steps aside, so nothing is ever trapped here.
@MainActor
final class PromptEditor: ObservableObject {
    @Published private(set) var line = PromptLine()
    @Published private(set) var isActive = false
    @Published private(set) var anchor: OctetTerminalRuntime.CursorAnchor?
    /// The greyed-out completion after the caret.
    @Published private(set) var suggestion: String?
    /// The completion menu, when it is open.
    @Published private(set) var completions: [Completion] = []
    @Published private(set) var completionIndex = 0
    /// Column the menu is anchored to: the start of the word being completed.
    @Published private(set) var completionColumn = 0
    /// ⌃R: the menu is searching history rather than completing a word.
    @Published private(set) var isSearchingHistory = false
    var completionsOpen: Bool { !completions.isEmpty }

    private unowned let store: SessionStore
    private var history = CommandHistory()
    private var historyLoadedAt = Date.distantPast
    /// The pane being typed into; the editor closes if focus moves.
    private var paneId: String?
    private var anchorTimer: Timer?
    /// Executables on PATH, read once; branches per working folder.
    private var pathCommands: [String] = []
    private var branches: [String] = []
    private var cwd: String?
    /// What this folder can run, and what usually follows what.
    private var projectCommands: [ProjectCommands.Entry] = []
    private var sequences = CommandSequences()
    /// The command submitted last, which drives the prediction.
    private var lastCommand: String?

    init(store: SessionStore) {
        self.store = store
        // Losing the window means the line is stale: hand it back rather
        // than keeping half a command no one can see.
        NotificationCenter.default.addObserver(
            forName: NSApplication.didResignActiveNotification, object: nil, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.flushOnFocusLoss() }
        }
    }

    /// The app went away with text in hand: give it to the shell.
    private func flushOnFocusLoss() {
        guard isActive else { return }
        flush()
    }

    /// Matches for the current text, for ↑ history stepping.
    private var historyMatches: [String] {
        line.isEmpty ? history.ranked(matching: "", limit: 0) : history.ranked(matching: line.text, limit: 50)
    }

    // MARK: - Key handling

    /// Called before the terminal sees a key; true means Octet took it.
    func handleKeyDown(_ event: NSEvent) -> Bool {
        guard SettingsStore.shared.values.promptEditor else { return false }
        if event.modifierFlags.contains(.command) {
            // Editing shortcuts belong to the line while it has the keyboard.
            guard isActive else { return false }
            return handleCommandKey(event)
        }
        guard isActive || store.keyPaneAtPrompt else {
            log("ignored key, atPrompt=\(store.keyPaneAtPrompt) process=\(String(describing: store.keyProcess))")
            return false
        }
        // The shell being in front isn't enough: `read -s` is the shell too.
        // Only a live line editor means this is a command line, not a secret.
        if !isActive {
            guard let pid = store.keyProcess?.shellPid,
                  ShellPrompt.lineEditorActive(shellPid: pid) == true else {
                log("ignored key, shell not in its line editor")
                return false
            }
        }
        guard let characters = event.charactersIgnoringModifiers, !characters.isEmpty else { return false }

        let control = event.modifierFlags.contains(.control)
        let option = event.modifierFlags.contains(.option)
        let shift = event.modifierFlags.contains(.shift)

        switch event.keyCode {
        case 36, 76: // Return
            guard isActive else { return false }
            if completionsOpen {
                acceptCompletion()
                return true
            }
            submit()
            return true
        case 53: // Escape
            guard isActive else { return false }
            // The menu closes first; a second escape hands the line back.
            if completionsOpen {
                closeCompletions()
                return true
            }
            flush()
            return true
        case 51: // Backspace
            guard isActive else { return false }
            if option || control {
                line.deleteWordBackward()
            } else {
                line.deleteBackward()
            }
            // An empty line means the shell should have the keyboard again.
            if line.isEmpty { deactivate() } else { refreshSuggestion() }
            return true
        case 117: // Forward delete
            guard isActive else { return false }
            line.deleteForward()
            refreshSuggestion()
            return true
        case 123: // ←
            guard isActive else { return false }
            if shift {
                line.extendingSelection { option ? $0.moveWordLeft() : $0.moveLeft() }
            } else {
                line.clearSelection()
                option ? line.moveWordLeft() : line.moveLeft()
            }
            refreshSuggestion()
            return true
        case 124: // →
            guard isActive else { return false }
            if shift {
                line.extendingSelection { option ? $0.moveWordRight() : $0.moveRight() }
                refreshSuggestion()
                return true
            }
            line.clearSelection()
            if option {
                if !line.acceptWord(of: suggestion) { line.moveWordRight() }
            } else if line.caretAtEnd, line.accept(suggestion: suggestion) {
                // Accepting the suggestion is what → means at the end.
            } else {
                line.moveRight()
            }
            refreshSuggestion()
            return true
        case 126, 125: // ↑ ↓
            guard isActive else { return false }
            if completionsOpen {
                let count = completions.count
                completionIndex = (completionIndex + (event.keyCode == 126 ? -1 : 1) + count) % count
                return true
            }
            line.stepHistory(event.keyCode == 126 ? 1 : -1, matches: historyMatches)
            refreshSuggestion()
            return true
        case 48: // Tab
            guard isActive else { return false }
            if completionsOpen {
                acceptCompletion()
            } else {
                openCompletions()
                // Nothing of Octet's to offer: let the shell try its own.
                if !completionsOpen { flush(then: "\t") }
            }
            return true
        default:
            break
        }

        if control {
            guard isActive else { return false }
            switch characters.lowercased() {
            case "a": line.moveToStart()
            case "e": line.moveToEnd()
            case "u": line.deleteToStart()
            case "k": line.deleteToEnd()
            case "w": line.deleteWordBackward()
            case "f": _ = line.accept(suggestion: suggestion)
            case "r":
                searchHistory()
                return true
            case "c":
                cancel()
                return true
            default:
                flush(then: characters)
                return true
            }
            if line.isEmpty, characters.lowercased() == "u" { deactivate() } else { refreshSuggestion() }
            return true
        }

        // Ordinary typing: a printable character starts or extends the line.
        guard let scalar = characters.unicodeScalars.first,
              !CharacterSet.controlCharacters.contains(scalar) else {
            guard isActive else { return false }
            flush(then: characters)
            return true
        }
        let text = shift ? (event.characters ?? characters) : (event.characters ?? characters)
        if !isActive { activate() }
        line.insert(text)
        refreshSuggestion()
        // A menu that is open follows what is being typed.
        if completionsOpen { openCompletions() }
        // Never log the typed text itself.
        log("length=\(line.text.count) suggestion=\(suggestion != nil) active=\(isActive) anchor=\(anchor != nil)")
        return true
    }

    // MARK: - Lifecycle

    private func log(_ message: String) {
        #if DEBUG
        guard ProcessInfo.processInfo.environment["OCTET_PROMPT_LOG"] != nil else { return }
        FileHandle.standardError.write(Data("octet: prompt \(message)\n".utf8))
        #endif
    }

    private func activate() {
        paneId = store.keyPaneId
        let pane = store.snapshot.panes.first { $0.paneId == paneId }
        cwd = pane?.effectiveCwd
        loadCompletionSources()
        line = PromptLine()
        anchor = OctetTerminalRuntime.cursorAnchor()
        isActive = true
        log("activate pane=\(paneId ?? "-") anchor=\(String(describing: anchor))")
        loadHistoryIfStale()
        // The prompt can move while typing (resize, output arriving).
        let timer = Timer(timeInterval: 0.25, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.followAnchor() }
        }
        RunLoop.main.add(timer, forMode: .common)
        anchorTimer = timer
    }

    private func followAnchor() {
        guard isActive else { return }
        // Focus moved, or the pane is running something now: step aside.
        let focused = store.keyPaneId
        guard store.keyPaneAtPrompt, focused == paneId else {
            // Whatever was typed belongs to the shell, not the bin.
            flush()
            return
        }
        let current = OctetTerminalRuntime.cursorAnchor()
        if current != anchor { anchor = current }
    }

    /// PATH and branches are disk work; read them off the main thread.
    private func loadCompletionSources() {
        let folder = cwd ?? NSHomeDirectory()
        let needsPath = pathCommands.isEmpty
        DispatchQueue.global(qos: .userInitiated).async {
            let commands = needsPath ? Completions.commandsOnPath() : []
            let branches = Completions.branches(in: folder)
            let project = ProjectCommands.all(in: folder)
            DispatchQueue.main.async { [weak self] in
                guard let self else { return }
                if needsPath { self.pathCommands = commands }
                self.branches = branches
                self.projectCommands = project
            }
        }
    }

    private func deactivate() {
        isActive = false
        closeCompletions()
        line = PromptLine()
        suggestion = nil
        anchor = nil
        paneId = nil
        anchorTimer?.invalidate()
        anchorTimer = nil
    }

    // MARK: - Completions

    /// Builds the menu for the word under the caret, from what the machine
    /// actually has: PATH, this folder, this repo's branches, your history.
    private func openCompletions() {
        let context = CompletionContext.at(caret: line.caret, in: line.text)
        let folder = cwd ?? NSHomeDirectory()
        // The spec for this command, from Octet's own table or the corpus.
        let spec = context.command.flatMap { SpecCorpus.merged(for: $0) }
        var generatorValues: [String] = []
        if let spec, let generator = Completions.generator(for: spec, words: context.wordsBeforeToken) {
            generatorValues = GeneratorCache.shared.values(generator, cwd: folder)
            // Stale values refresh behind the menu and reopen it when ready.
            GeneratorCache.shared.refreshIfStale(generator, cwd: folder) { [weak self] in
                guard let self, self.completionsOpen else { return }
                self.openCompletions()
            }
        }
        let results = Completions.suggestions(
            for: context,
            commands: pathCommands,
            entries: Completions.entries(for: context.token, cwd: folder),
            history: history.entries.map(\.command),
            branches: branches,
            spec: spec,
            generatorValues: generatorValues,
            project: projectCommands,
            predictions: sequences.next(after: lastCommand)
        )
        completions = results
        completionIndex = 0
        completionColumn = context.range.lowerBound
        isSearchingHistory = false
    }

    /// ⌃R: the same menu, searching everything you have run.
    private func searchHistory() {
        let needle = line.text
        let matches = needle.isEmpty
            ? history.entries.prefix(30).map(\.command)
            : history.ranked(matching: needle, limit: 30)
        let fuzzy = needle.isEmpty ? [] : history.entries.map(\.command).filter {
            !$0.hasPrefix(needle) && FuzzyMatcher.match(needle, in: $0) != nil
        }
        completions = (matches + fuzzy).prefix(30).map { Completion(value: $0, kind: .history) }
        completionIndex = 0
        completionColumn = 0
        isSearchingHistory = !completions.isEmpty
    }

    private func closeCompletions() {
        completions = []
        completionIndex = 0
        isSearchingHistory = false
    }

    /// Puts the highlighted entry into the line.
    func acceptCompletion() {
        guard completions.indices.contains(completionIndex) else { return }
        let completion = completions[completionIndex]
        if isSearchingHistory {
            line.replace(range: 0..<line.text.count, with: completion.value)
        } else {
            let context = CompletionContext.at(caret: line.caret, in: line.text)
            // Directories keep the slash so the next word continues the path.
            let value = completion.kind == .directory ? completion.value : completion.value + " "
            line.replace(range: context.range, with: value)
        }
        closeCompletions()
        refreshSuggestion()
    }

    func selectCompletion(_ index: Int) {
        guard completions.indices.contains(index) else { return }
        completionIndex = index
    }

    // MARK: - Command-key editing

    private func handleCommandKey(_ event: NSEvent) -> Bool {
        let shift = event.modifierFlags.contains(.shift)
        switch event.charactersIgnoringModifiers?.lowercased() {
        case "v":
            guard let pasted = NSPasteboard.general.string(forType: .string) else { return true }
            // A trailing newline would run the command; paste the text only.
            line.insert(pasted.trimmingCharacters(in: .newlines))
            refreshSuggestion()
            return true
        case "c":
            guard let selected = line.selectedText else { return false }
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(selected, forType: .string)
            ClipboardWatcher.shared.acknowledge()
            return true
        case "x":
            guard let selected = line.selectedText else { return false }
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(selected, forType: .string)
            ClipboardWatcher.shared.acknowledge()
            line.deleteSelection()
            refreshSuggestion()
            return true
        case "a":
            line.selectAll()
            return true
        case "z":
            shift ? line.redo() : line.undo()
            refreshSuggestion()
            return true
        default:
            return false
        }
    }

    // MARK: - Sending

    /// Return: hand the finished command to the shell.
    private func submit() {
        let command = line.text
        send(command + "\r")
        if !command.trimmingCharacters(in: .whitespaces).isEmpty {
            history.add(.init(command: command, at: Date()))
            // Learn the pair, so next time the line starts where you left off.
            if let previous = lastCommand {
                sequences.add(previous: previous, next: command, at: Int(Date().timeIntervalSince1970))
            }
            sequences.add(command: command, in: cwd)
            lastCommand = command
        }
        deactivate()
    }

    /// Escape, Tab, or a key Octet doesn't handle: give the shell what was
    /// typed and get out of the way.
    private func flush(then trailing: String = "") {
        let text = line.text + trailing
        if !text.isEmpty { send(text) }
        deactivate()
    }

    /// ⌃C: let the shell clear its own line.
    private func cancel() {
        send("\u{3}")
        deactivate()
    }

    private func send(_ text: String) {
        guard let paneId else { return }
        let client = store.client
        DispatchQueue.global(qos: .userInitiated).async {
            let outcome = Result { try client.call("pane.send_text", ["pane_id": paneId, "text": text]) }
            if case .failure(let error) = outcome {
                DispatchQueue.main.async {
                    ToastCenter.shared.fail(nil, "Couldn't send that to the terminal", detail: String(describing: error))
                }
            }
        }
    }

    // MARK: - Suggestions

    private func refreshSuggestion() {
        guard line.caretAtEnd, !line.isBrowsingHistory, line.selection == nil else {
            suggestion = nil
            return
        }
        // What usually follows the last command wins over a plain history
        // match, since it knows where you are in a sequence.
        suggestion = sequences.prediction(after: lastCommand, matching: line.text, in: cwd)
            ?? history.suggestion(for: line.text)
    }

    /// History is read from the shells' own files, off the main thread.
    private func loadHistoryIfStale() {
        guard Date().timeIntervalSince(historyLoadedAt) > 60 else { return }
        historyLoadedAt = Date()
        DispatchQueue.global(qos: .userInitiated).async {
            let loaded = CommandHistory.load()
            // The order in the file is the order they were run: that is what
            // makes the sequence table worth having.
            let sequences = CommandSequences(history: loaded.entries.map(\.command))
            DispatchQueue.main.async { [weak self] in
                guard let self else { return }
                // Keep anything typed this session on top of the file's.
                var merged = loaded
                for entry in self.history.entries { merged.add(entry) }
                self.history = merged
                self.sequences = sequences
                self.refreshSuggestion()
            }
        }
    }
}
