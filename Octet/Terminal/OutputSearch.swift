import AppKit

/// A native Find panel that searches retained output and scrolls the live pane.
@MainActor
final class OutputSearch: NSWindowController, NSSearchFieldDelegate, NSWindowDelegate {
    static func perform(_ action: NSTextFinder.Action = .showFindInterface) {
        let key = NSApp.keyWindow
        if let context = WindowRegistry.shared.windows.first(where: {
            $0.nsWindow === key || $0.nsWindow === key?.parent
        }) {
            context.findOutput(action)
        } else {
            let item = NSMenuItem()
            item.tag = action.rawValue
            NSApp.sendAction(#selector(NSTextView.performTextFinderAction(_:)), to: nil, from: item)
        }
    }

    private let client: EngineClient
    let paneId: String
    private let query = NSSearchField()
    private let status = NSTextField(labelWithString: "Search this pane's retained output. Press Return to find.")
    private let next = NSButton(title: "Next", target: nil, action: nil)
    private let previous = NSButton(title: "Previous", target: nil, action: nil)
    private var result: TerminalSearchResult?
    private var searchedQuery = ""
    private var generation = 0
    private var busy = false
    private var pendingReveal: DispatchWorkItem?
    private let queue = DispatchQueue(label: "com.jpxsoftware.octet.find", qos: .userInitiated)

    init(client: EngineClient, paneId: String) {
        self.client = client
        self.paneId = paneId
        let panel = FindPanel(contentRect: NSRect(x: 0, y: 0, width: 540, height: 92),
                             styleMask: [.titled, .closable], backing: .buffered, defer: false)
        panel.title = "Find in Terminal Output"
        panel.isReleasedWhenClosed = false
        panel.isFloatingPanel = false
        super.init(window: panel)
        panel.delegate = self
        panel.dismiss = { [weak self] in self?.dismiss() }
        let content = NSView()
        panel.contentView = content
        query.placeholderString = "Find in output"
        query.delegate = self
        query.target = self
        query.action = #selector(findNext)
        query.sendsWholeSearchString = true
        query.sendsSearchStringImmediately = false
        query.setAccessibilityLabel("Find in terminal output")
        next.target = self
        next.action = #selector(findNext)
        previous.target = self
        previous.action = #selector(findPrevious)
        let done = NSButton(title: "Done", target: self, action: #selector(dismiss))
        let controls = NSStackView(views: [query, previous, next, done])
        controls.spacing = 8
        query.setContentHuggingPriority(.defaultLow, for: .horizontal)
        status.font = .systemFont(ofSize: 11)
        status.lineBreakMode = .byTruncatingTail
        for view in [controls, status] {
            view.translatesAutoresizingMaskIntoConstraints = false
            content.addSubview(view)
        }
        NSLayoutConstraint.activate([
            controls.topAnchor.constraint(equalTo: content.topAnchor, constant: 12),
            controls.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: 12),
            controls.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -12),
            status.topAnchor.constraint(equalTo: controls.bottomAnchor, constant: 10),
            status.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: 12),
            status.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -12),
            status.bottomAnchor.constraint(lessThanOrEqualTo: content.bottomAnchor, constant: -10),
        ])
    }

    required init?(coder: NSCoder) { fatalError("not supported") }

    func present(on parent: NSWindow) {
        guard let window else { return }
        window.setFrameTopLeftPoint(NSPoint(x: max(parent.frame.minX, parent.frame.maxX - window.frame.width - 16),
                                           y: parent.frame.maxY - 90))
        parent.addChildWindow(window, ordered: .above)
        window.makeKeyAndOrderFront(nil)
        query.stringValue = NSPasteboard(name: .find).string(forType: .string) ?? ""
        find()
    }

    func find(_ action: NSTextFinder.Action = .showFindInterface) {
        switch action {
        case .nextMatch: search(backward: false)
        case .previousMatch: search(backward: true)
        default:
            window?.makeKeyAndOrderFront(nil)
            window?.makeFirstResponder(query)
            query.selectText(nil)
        }
    }

    @objc private func findNext() { search(backward: false) }
    @objc private func findPrevious() { search(backward: true) }

    #if DEBUG
    /// Verification hook: types a query and finds it.
    func debugFind(_ text: String) {
        query.stringValue = text
        search(backward: true)
    }
    #endif

    private func setBusy(_ value: Bool) {
        busy = value
        next.isEnabled = !value
        previous.isEnabled = !value
    }

    private func search(backward: Bool) {
        let text = query.stringValue
        guard !busy, !text.isEmpty else { return }
        let prior = searchedQuery == text ? result : nil
        let client = client, paneId = paneId
        generation += 1
        let requestID = generation
        setBusy(true)
        status.stringValue = "Searching…"
        status.toolTip = nil
        let pasteboard = NSPasteboard(name: .find)
        pasteboard.clearContents()
        pasteboard.setString(text, forType: .string)
        queue.async { [weak self] in
            let outcome = Result { try TerminalSearchResult.find(paneId: paneId, query: text,
                backward: backward, previous: prior, request: client.call) }
            DispatchQueue.main.async {
                guard let self, self.generation == requestID else { return }
                guard self.query.stringValue == text else {
                    self.setBusy(false)
                    self.status.stringValue = "Query changed. Press Return to find."
                    return
                }
                switch outcome {
                case .failure(let error): self.finish(error: error)
                case .success(let found):
                    self.result = found
                    self.searchedQuery = text
                    guard found.match != nil else {
                        self.setBusy(false)
                        self.status.stringValue = "No matches in retained output."
                        return
                    }
                    self.reveal(found, requestID: requestID)
                }
            }
        }
    }

    private func reveal(_ found: TerminalSearchResult, requestID: Int) {
        let client = client, paneId = paneId
        let work = DispatchWorkItem { [weak self] in
            let outcome = Result {
                let current = try client.call("pane.copy_motion", ["pane_id": paneId,
                    "cursor": ["row": 0, "col": 0], "motion": "line_end"])
                guard current["content_revision"] as? UInt64 == found.revision else {
                    throw EngineSocketError.server(code: "stale_content", message: "Output changed. Find again to refresh matches.")
                }
                let response = try client.call("pane.get", ["pane_id": paneId])
                guard let pane = response["pane"] as? [String: Any],
                      let scroll = pane["scroll"] as? [String: Any],
                      let maximum = scroll["max_offset_from_bottom"] as? Int,
                      let rows = scroll["viewport_rows"] as? Int,
                      let offset = found.scrollOffset(maximum: maximum, viewportRows: rows) else {
                    throw EngineSocketError.malformedResponse("This pane has no scrollback viewport")
                }
                // Dismissal or edits invalidate the pending mutation while the
                // read-only engine calls are in flight.
                let valid = DispatchQueue.main.sync {
                    self?.generation == requestID && self?.query.stringValue == self?.searchedQuery
                }
                guard valid else { return }
                _ = try client.call("pane.scroll", ["pane_id": paneId, "offset_from_bottom": offset])
                // Where the match sits in the view now, for the highlight.
                if let match = found.match {
                    let top = maximum - offset
                    let highlight = SearchHighlight.Box(paneId: paneId, row: match.start.row - top,
                                                        startColumn: match.start.col,
                                                        endColumn: match.end.row == match.start.row ? match.end.col : nil)
                    DispatchQueue.main.async { SearchHighlight.shared.box = highlight }
                }
            }
            DispatchQueue.main.async {
                guard let self, self.generation == requestID else { return }
                switch outcome {
                case .failure(let error): self.finish(error: error)
                case .success:
                    self.setBusy(false)
                    self.status.stringValue = "Match \(found.ordinal ?? 1) of \(found.total) — shown in the terminal."
                }
            }
        }
        pendingReveal = work
        queue.async(execute: work)
    }

    func control(_ control: NSControl, textView: NSTextView, doCommandBy commandSelector: Selector) -> Bool {
        if commandSelector == #selector(NSResponder.cancelOperation(_:)) {
            dismiss()
            return true
        }
        return false
    }

    private func finish(error: Error) {
        setBusy(false)
        status.stringValue = "Couldn't search: \(error)"
        status.toolTip = String(describing: error)
    }

    func windowShouldClose(_ sender: NSWindow) -> Bool {
        dismiss()
        return false
    }

    @objc func dismiss() {
        SearchHighlight.shared.box = nil
        generation += 1
        pendingReveal?.cancel()
        pendingReveal = nil
        setBusy(false)
        guard let window else { return }
        if let parent = window.parent {
            parent.removeChildWindow(window)
            parent.makeKeyAndOrderFront(nil)
            parent.makeFirstResponder((WindowRegistry.shared.windows.first { $0.nsWindow === parent })?.surface)
        }
        window.orderOut(nil)
    }
}

private final class FindPanel: NSPanel {
    var dismiss: (() -> Void)?
    override func cancelOperation(_ sender: Any?) { dismiss?() }
}
