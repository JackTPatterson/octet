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
    /// Which shells already hold part of the line; Octet stays out of those
    /// until the line is run or cleared. Saved, since shells outlive Octet.
    private var shellLines = PromptEditor.loadShellLines() {
        didSet {
            guard shellLines.holding != oldValue.holding else { return }
            UserDefaults.standard.set(Array(shellLines.holding), forKey: Self.shellLinesKey)
        }
    }
    private static let shellLinesKey = "octet.shellHoldsLine"

    private static func loadShellLines() -> ShellLineTracker {
        let saved = Set(UserDefaults.standard.stringArray(forKey: shellLinesKey) ?? [])
        // A shell that exited took its line with it.
        return ShellLineTracker(holding: saved).pruned { kill(pid_t($0), 0) == 0 }
    }

    /// Octet's sends still on their way to each pane. Keys typed meanwhile
    /// wait in `heldKeys`, so they can't reach the shell ahead of them.
    private var sendsInFlight: [String: Int] = [:]
    private enum Held {
        case key(NSEvent, NSView)
        case paste(String, pane: String)
    }
    private var heldKeys: [Held] = []

    /// Hands held input on in the order it came, once nothing of Octet's is
    /// still on its way: keys to the terminal views they were typed into,
    /// pastes back onto the queue (and the rest waits for them in turn).
    private func releaseHeldKeys() {
        while sendsInFlight.isEmpty, !heldKeys.isEmpty {
            switch heldKeys.removeFirst() {
            case .key(let event, let view):
                OctetKeyHook.replaying = true
                view.keyDown(with: event)
                OctetKeyHook.replaying = false
            case .paste(let text, let pane):
                send(text, to: pane)
            }
        }
    }

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

    /// All native paste routes must edit the held line before reaching the PTY.
    @discardableResult
    func insertPastedText(_ text: String) -> Bool {
        guard isActive, paneId == store.keyPaneId else {
            guard !isActive, let pane = store.keyPaneId else { return false }
            // The paste goes to the shell's own line, behind any of Octet's
            // text still on its way there.
            shellLines.keyReachedPane(lineKey(pane), .text)
            if !sendsInFlight.isEmpty || !heldKeys.isEmpty {
                // As a paste: escapes stripped, and lines bracketed so they
                // don't run one by one. It waits behind anything held.
                heldKeys.append(.paste(PromptLine(text: PromptLine.pastedText(text)).shellInput(), pane: pane))
                releaseHeldKeys()
                return true
            }
            return false
        }
        line.insert(PromptLine.pastedText(text))
        refreshSuggestion()
        if completionsOpen { closeCompletions() }
        return true
    }

    func selectAll() -> Bool {
        guard isActive, paneId == store.keyPaneId else { return false }
        line.selectAll()
        refreshSuggestion()
        return true
    }

    func copySelection() -> Bool {
        guard isActive, paneId == store.keyPaneId, let selected = line.selectedText else { return false }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(selected, forType: .string)
        ClipboardWatcher.shared.acknowledge()
        return true
    }

    /// Called before the terminal sees a key; true means Octet took it.
    func handleKeyDown(_ event: NSEvent) -> Bool {
        if !isActive, let pane = store.keyPaneId {
            // Octet's own text is still being delivered: hold this key until
            // it lands, then give it to the terminal, which encodes it for
            // whatever mode the pane is in. ⌘ shortcuts are the app's own.
            if !sendsInFlight.isEmpty || !heldKeys.isEmpty, !event.modifierFlags.contains(.command),
               let view = event.window?.firstResponder as? NSView {
                heldKeys.append(.key(event, view))
                shellLines.keyReachedPane(lineKey(pane), Self.lineEffect(of: event))
                return true
            }
            shellLines.observe(lineKey(pane), programInFront: shellEditingLine(in: pane).map { !$0 })
        }
        let wasActive = isActive
        let taken = takeKey(event)
        if !taken, !wasActive, let pane = store.keyPaneId {
            shellLines.keyReachedPane(lineKey(pane), Self.lineEffect(of: event))
        }
        return taken
    }

    /// The tracker's key for the shell in `pane`.
    private func lineKey(_ pane: String) -> String {
        ShellLineTracker.key(pane: pane, shellPid: shellPid(for: pane))
    }

    /// What a key Octet let through does to the shell's own line.
    private static func lineEffect(of event: NSEvent) -> ShellLineTracker.Key {
        let flags = event.modifierFlags
        let key = event.charactersIgnoringModifiers?.lowercased()
        if event.keyCode == 36 || event.keyCode == 76 { return .submit }
        if flags.contains(.command) { return .other }
        if flags.contains(.control) { return key == "c" || key == "u" ? .clear : .other }
        // ↑ recalls history into the line.
        if event.keyCode == 126 { return .text }
        guard let characters = event.characters, let scalar = characters.unicodeScalars.first else { return .other }
        // Arrows and function keys arrive as private-use characters.
        if CharacterSet.controlCharacters.contains(scalar) || (0xF700...0xF8FF).contains(scalar.value) { return .other }
        return .text
    }

    private func takeKey(_ event: NSEvent) -> Bool {
        guard SettingsStore.shared.values.promptEditor else { return false }
        if event.modifierFlags.contains(.command) {
            // Editing shortcuts belong to the line while it has the keyboard.
            guard isActive else { return false }
            return handleCommandKey(event)
        }
        // Only the shell's own line editor, checked live, means this is a
        // command line: not a program the shell started, and not `read -s`
        // asking for a secret. The process snapshot can lag a second behind
        // a command finishing, so it doesn't decide this.
        if !isActive {
            if let pane = store.keyPaneId, shellLines.holdsLine(lineKey(pane)) {
                log("ignored key, the shell holds part of this line")
                return false
            }
            guard shellEditingLine(in: store.keyPaneId) == true else {
                log("ignored key, shell not in its line editor")
                return false
            }
            // Text the shell got some way Octet didn't see (its own Tab
            // completion, an accepted autosuggestion) with the cursor moved
            // back into it. Octet's line would start at the cursor, cover
            // the rest, and insert there on Return.
            if let pane = store.keyPaneId, let rest = OctetTerminalRuntime.textRightOfCursor(),
               ShellPrompt.lineContinues(afterCursor: rest) {
                log("ignored key, the shell's line goes on past the cursor")
                shellLines.keyReachedPane(lineKey(pane), .text)
                return false
            }
        }
        guard let characters = event.charactersIgnoringModifiers, !characters.isEmpty else { return false }

        let control = event.modifierFlags.contains(.control)
        let option = event.modifierFlags.contains(.option)
        let shift = event.modifierFlags.contains(.shift)

        switch event.keyCode {
        case 48 where option && isActive:
            // ⌥⇥: straight to the shell's own completion, past Octet's.
            flush(then: "\t")
            return true
        case 117 where shift && isActive && suggestion != nil:
            // ⇧⌦ on a suggestion: never suggest it again.
            forget(suggestion!)
            return true
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
            if line.isEmpty { deactivate() } else { refreshSuggestion(); followMenu() }
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
            if !SettingsStore.shared.values.promptCompletions, !isSearchingHistory {
                flush(then: "\t")
                return true
            }
            if completionsOpen {
                acceptCompletion()
            } else {
                openCompletions()
                if completionsOpen { return true }
                // `git clone⇥`: the word is whole; finish it and move on to
                // what comes next, as the shell would.
                if finishWordAtCaret() { return true }
                // Values are on their way; the menu opens when they land.
                if awaitingValues {
                    menuRequested = true
                    return true
                }
                // Nothing of Octet's to offer: let the shell try its own.
                flush(then: "\t")
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
        followMenu()
        // Plugins with slow lists start fetching while the command is still
        // being typed, so the menu opens full.
        if SettingsStore.shared.values.promptCompletions {
            OctetPluginHost.shared.prefetch(line: line.text, cwd: cwd ?? NSHomeDirectory())
        }
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
        guard focused == paneId, shellEditingLine(in: paneId) != false else {
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
        menuRequested = false
        closeCompletions()
        line = PromptLine()
        suggestion = nil
        anchor = nil
        paneId = nil
        anchorTimer?.invalidate()
        anchorTimer = nil
    }

    // MARK: - Completions

    /// The menu's values are still being fetched for the word at the caret.
    private var awaitingValues = false
    /// Tab asked for the menu while its values were on their way.
    private var menuRequested = false

    private func finishWordAtCaret() -> Bool {
        let context = CompletionContext.at(caret: line.caret, in: line.text)
        guard line.caret == context.range.upperBound,
              Completions.isCompleteWord(context, spec: context.command.flatMap { OctetPluginHost.shared.spec(for: $0) },
                                         commands: pathCommands) else { return false }
        line.insert(" ")
        refreshSuggestion()
        followMenu()
        return true
    }

    /// Each pane's shell, which lives as long as the pane.
    private var shellPids: [String: Int] = [:]

    /// Whether `pane`'s shell is in its own line editor right now, read from
    /// the terminal itself; nil when that can't be told.
    private func shellEditingLine(in pane: String?) -> Bool? {
        guard let pane else { return nil }
        if let pid = shellPid(for: pane), let editing = ShellPrompt.lineEditorActive(shellPid: pid) {
            return editing
        }
        // The shell was replaced (`exec zsh`); ask once more.
        shellPids[pane] = nil
        return shellPid(for: pane).flatMap { ShellPrompt.lineEditorActive(shellPid: $0) }
    }

    private func shellPid(for pane: String) -> Int? {
        if let pid = shellPids[pane] { return pid }
        // One quick call to the local engine, once per pane.
        let pid = (try? store.client.call("pane.process_info", ["pane_id": pane]))
            .flatMap(ShellPrompt.parse)?.shellPid
        shellPids[pane] = pid
        return pid
    }

    /// An open menu follows the line; a closed one opens where a plugin
    /// asks for it.
    private func followMenu() {
        if completionsOpen || menuRequested {
            menuRequested = false
            openCompletions()
        } else if opensByItself {
            openCompletions(automatic: true)
        }
    }

    /// The line is at a point where a plugin shows the menu without Tab.
    private var opensByItself: Bool {
        SettingsStore.shared.values.promptCompletions
            && OctetPluginHost.shared.opensMenu(String(line.text.prefix(line.caret)))
    }

    /// Builds the menu for the word under the caret, from what the machine
    /// actually has: PATH, this folder, this repo's branches, your history.
    private func openCompletions(automatic: Bool = false) {
        let context = CompletionContext.at(caret: line.caret, in: line.text)
        let folder = cwd ?? NSHomeDirectory()
        // The spec for this command, from Octet's own table or the corpus.
        let spec = context.command.flatMap { OctetPluginHost.shared.spec(for: $0) }
        var generatorValues: [String] = []
        awaitingValues = false
        if let spec, let generator = Completions.generator(for: spec, words: context.wordsBeforeToken) {
            generatorValues = GeneratorCache.shared.values(generator, cwd: folder)
            // Stale values refresh behind the menu and reopen it when ready.
            GeneratorCache.shared.refreshIfStale(generator, cwd: folder) { [weak self] in
                guard let self, self.isActive else { return }
                self.followMenu()
            }
            awaitingValues = generatorValues.isEmpty && GeneratorCache.shared.isLoading(generator, cwd: folder)
            // Opening by itself waits for the values; a menu of flags that
            // then jumps to repositories is worse than a moment's wait.
            if automatic, generatorValues.isEmpty {
                closeCompletions()
                return
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
            return OctetKeyHook.paste()
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
            return selectAll()
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
        // A bare `claude`, `codex` or `opencode` opens Octet's conversation
        // view instead, when that's what the setting says. Nothing has gone
        // to the shell, so its prompt is left as it was.
        if SettingsStore.shared.values.agentOpening == .octet,
           let agent = AgentLaunch.agent(inCommandLine: command),
           store.keyWindow?.openAgentConversation(agent, inPane: paneId) == true {
            remember(command)
            deactivate()
            return
        }
        send(line.shellInput(trailing: "\r"))
        remember(command)
        deactivate()
    }

    /// History and the sequences it learns from, for a command that was run.
    private func remember(_ command: String) {
        if !command.trimmingCharacters(in: .whitespaces).isEmpty {
            history.add(.init(command: command, at: Date()))
            // Learn the pair, so next time the line starts where you left off.
            if let previous = lastCommand {
                sequences.add(previous: previous, next: command, at: Int(Date().timeIntervalSince1970))
            }
            sequences.add(command: command, in: cwd)
            lastCommand = command
        }
    }

    /// Escape, Tab, or a key Octet doesn't handle: give the shell what was
    /// typed and get out of the way.
    private func flush(then trailing: String = "") {
        let text = line.shellInput(trailing: trailing, restoreCaret: true)
        if !text.isEmpty {
            send(text)
            if let paneId { shellLines.handedLine(lineKey(paneId), submitted: text.hasSuffix("\r")) }
        }
        deactivate()
    }

    /// ⌃C: let the shell clear its own line.
    private func cancel() {
        send("\u{3}")
        deactivate()
    }

    private func send(_ text: String) {
        guard let paneId else { return }
        send(text, to: paneId)
    }

    /// Sends in order on the shared input queue, counting what's still on
    /// its way so keys typed meanwhile can wait their turn.
    private func send(_ text: String, to pane: String) {
        let client = store.client
        sendsInFlight[pane, default: 0] += 1
        EngineClient.inputQueue.async {
            let outcome = Result { try client.call("pane.send_text", ["pane_id": pane, "text": text]) }
            DispatchQueue.main.async {
                MainActor.assumeIsolated {
                    let remaining = (self.sendsInFlight[pane] ?? 1) - 1
                    self.sendsInFlight[pane] = remaining > 0 ? remaining : nil
                    self.releaseHeldKeys()
                    if case .failure(let error) = outcome {
                        ToastCenter.shared.fail(nil, "Couldn't send that to the terminal", detail: String(describing: error))
                    }
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
        let predicted = sequences.prediction(after: lastCommand, matching: line.text, in: cwd)
        suggestion = predicted.flatMap { history.hidden.contains($0) ? nil : $0 }
            ?? history.suggestion(for: line.text)
    }

    private static let hiddenKey = "octet.history.hidden"

    /// Stops suggesting `command`, with an Undo.
    private func forget(_ command: String) {
        history.hidden.insert(command)
        UserDefaults.standard.set(Array(history.hidden).sorted(), forKey: Self.hiddenKey)
        refreshSuggestion()
        ToastCenter.shared.info("Won't suggest that again", detail: command, action: .init(title: "Undo") { [weak self] in
            guard let self else { return }
            self.history.hidden.remove(command)
            UserDefaults.standard.set(Array(self.history.hidden).sorted(), forKey: Self.hiddenKey)
            self.refreshSuggestion()
        })
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
                merged.hidden = Set(UserDefaults.standard.stringArray(forKey: Self.hiddenKey) ?? [])
                self.history = merged
                self.sequences = sequences
                self.refreshSuggestion()
            }
        }
    }
}
