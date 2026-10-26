import AppKit
import SwiftUI

/// AppKit's text system supplies the editor mechanics that should feel native:
/// selection, undo, IME input, Services, drag/drop and the system find bar.
/// SwiftUI owns the surrounding file UI; this view only owns the buffer.
struct CodeEditorTextView: NSViewRepresentable {
    @ObservedObject var document: EditorDocument
    @ObservedObject private var settings = SettingsStore.shared
    /// Agents' edits in flight, for the cursor that shows where one will land.
    @ObservedObject private var activity = AgentEditActivity.shared
    @AppStorage("octet.editor.followAgent") private var followAgent = true
    let workspace: EditorWorkspace

    func makeCoordinator() -> Coordinator { Coordinator(document: document, workspace: workspace) }

    func makeNSView(context: Context) -> NSScrollView {
        // A TextKit 1 view, built the way Apple's text system guide does it.
        // `scrollableTextView()` hands back a TextKit 2 view, and the line
        // ruler and the highlighter both ask for its `layoutManager`, which
        // makes AppKit switch it to TextKit 1 at runtime; done during a
        // draw, that leaves the line numbers laid out and the text blank.
        let scroll = NSScrollView()
        let textView = EditorNSTextView(usingTextLayoutManager: false)
        textView.minSize = NSSize(width: 0, height: 0)
        textView.maxSize = NSSize(width: CGFloat.greatestFiniteMagnitude, height: CGFloat.greatestFiniteMagnitude)
        textView.isHorizontallyResizable = false
        textView.autoresizingMask = [.width]
        textView.textContainer?.containerSize = NSSize(width: 0, height: CGFloat.greatestFiniteMagnitude)
        textView.textContainer?.widthTracksTextView = true
        scroll.documentView = textView
        textView.delegate = context.coordinator
        textView.isRichText = false
        textView.usesAdaptiveColorMappingForDarkAppearance = false
        textView.drawsBackground = true
        textView.importsGraphics = false
        textView.isAutomaticQuoteSubstitutionEnabled = false
        textView.isAutomaticDashSubstitutionEnabled = false
        textView.isAutomaticTextReplacementEnabled = false
        textView.isAutomaticSpellingCorrectionEnabled = false
        textView.allowsUndo = true
        textView.isIncrementalSearchingEnabled = true
        textView.usesFindBar = true
        textView.isVerticallyResizable = true
        textView.textContainerInset = NSSize(width: 12, height: 12)
        textView.textContainer?.lineFragmentPadding = 4
        textView.string = document.text

        scroll.hasVerticalScroller = true
        scroll.hasHorizontalScroller = false
        scroll.autohidesScrollers = true
        scroll.scrollerStyle = .overlay
        scroll.drawsBackground = true
        scroll.borderType = .noBorder
        scroll.contentView.postsBoundsChangedNotifications = true
        scroll.hasVerticalRuler = true
        scroll.rulersVisible = true
        let ruler = LineNumberRulerView(textView: textView)
        scroll.verticalRulerView = ruler
        context.coordinator.textView = textView
        context.coordinator.ruler = ruler
        textView.textStorage?.delegate = context.coordinator
        let coordinator = context.coordinator
        coordinator.live.attach(textView: textView, scroll: scroll)
        coordinator.live.repaint = { [weak coordinator] immediately in coordinator?.highlightSoon(immediate: immediately) }
        coordinator.live.typedText = { [weak coordinator] typing in coordinator?.isTypingAgentText = typing }
        activity.start()
        workspace.textView = textView
        applyAppearance(to: textView, scroll: scroll, ruler: ruler)
        // Defer syntax coloring until after the native text system has drawn
        // its initial buffer at least once.
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) {
            context.coordinator.highlightSoon(immediate: true)
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) {
            scroll.contentView.scroll(to: .zero)
            scroll.reflectScrolledClipView(scroll.contentView)
            textView.scrollRangeToVisible(NSRange(location: 0, length: 0))
            textView.window?.makeFirstResponder(textView)
        }
        return scroll
    }

    func updateNSView(_ scroll: NSScrollView, context: Context) {
        guard let textView = scroll.documentView as? NSTextView else { return }
        context.coordinator.document = document
        context.coordinator.workspace = workspace
        workspace.textView = textView
        applyAppearance(to: textView, scroll: scroll, ruler: context.coordinator.ruler)
        // A new theme or font repaints everything; typing repaints its lines.
        context.coordinator.appearanceChanged(font: textView.font, palette: Theme.palette)
        let coordinator = context.coordinator
        coordinator.live.enabled = settings.values.showAgentCursors
        coordinator.setVim(enabled: settings.values.vimMode, in: textView, scroll: scroll)
        if textView.string != document.text, !coordinator.isApplyingHighlight, !coordinator.live.isTyping {
            if let change = document.liveChange, !coordinator.live.hasShown(change),
               coordinator.live.canType(change, current: textView.string, final: document.text) {
                // An agent's edit lands as typing, in its own cursor's hands.
                coordinator.live.type(change, final: document.text, follow: followAgent)
            } else {
                let selection = textView.selectedRanges
                coordinator.isReplacingText = true
                textView.string = document.text
                textView.selectedRanges = selection.compactMap { value in
                    let range = value.rangeValue
                    return NSValue(range: NSRange(location: min(range.location, document.text.utf16.count), length: 0))
                }
                coordinator.isReplacingText = false
                coordinator.highlightSoon(immediate: true)
            }
        }
        if !coordinator.live.isTyping, textView.string == document.text {
            // A change that came in as a whole: light it and move the cursor there.
            if let change = document.liveChange, !coordinator.live.hasShown(change), Date().timeIntervalSince(change.at) < 5 {
                coordinator.live.present(change, follow: followAgent)
            }
            // An edit the agent has started: its cursor where the edit will land.
            if let pending = activity.pending[document.id] {
                let place = pending.oldString.flatMap { LiveEdit.location(of: $0, in: document.text) } ?? 0
                coordinator.live.showPending(at: place, writer: pending.writer, follow: followAgent)
            } else {
                coordinator.live.showPending(at: nil, writer: nil, follow: false)
            }
        }
    }

    private func applyAppearance(to textView: NSTextView, scroll: NSScrollView, ruler: LineNumberRulerView?) {
        let palette = Theme.palette
        let background = palette.nsColor(\.background)
        let family = settings.values.fontFamily
        let editorFont: NSFont = family.isEmpty
            ? .monospacedSystemFont(ofSize: settings.values.fontSize, weight: .regular)
            : NSFont(name: family, size: settings.values.fontSize) ?? .monospacedSystemFont(ofSize: settings.values.fontSize, weight: .regular)
        // On a plain-text view these two recolour and refont the whole buffer,
        // erasing the syntax colours; so only when they actually change, not on
        // every update a keystroke causes.
        if textView.font != editorFont { textView.font = editorFont }
        let plain = palette.nsColor(\.textPrimary)
        if let coordinator = textView.delegate as? Coordinator {
            if coordinator.appliedTextColor != plain {
                textView.textColor = plain
                coordinator.appliedTextColor = plain
            }
        } else {
            textView.textColor = plain
        }
        textView.typingAttributes = [
            .font: editorFont,
            .foregroundColor: palette.nsColor(\.textPrimary),
        ]
        textView.insertionPointColor = palette.nsColor(\.accent)
        textView.selectedTextAttributes = [
            .backgroundColor: palette.nsColor(\.cardSelected),
            .foregroundColor: palette.nsColor(\.textPrimary),
        ]
        textView.backgroundColor = background
        scroll.backgroundColor = background
        ruler?.backgroundColor = palette.nsColor(\.chrome)
        ruler?.foregroundColor = palette.nsColor(\.textTertiary)
        ruler?.font = textView.font ?? .monospacedSystemFont(ofSize: 13, weight: .regular)
        ruler?.needsDisplay = true
    }

    @MainActor
    final class Coordinator: NSObject, NSTextViewDelegate, NSTextStorageDelegate {
        var document: EditorDocument
        weak var workspace: EditorWorkspace?
        weak var textView: NSTextView?
        weak var ruler: LineNumberRulerView?
        var isReplacingText = false
        /// The agent's edit is being typed into the view, so the view isn't the document's text yet.
        var isTypingAgentText = false
        let live = AgentLiveLayer()
        /// The text colour last set on the view (see `applyAppearance`).
        var appliedTextColor: NSColor?
        var isApplyingHighlight = false
        private var highlightWork: DispatchWorkItem?
        /// Characters edited since the last paint; nil repaints everything.
        private var pending: NSRange?
        private var paintsAll = true
        private var paintedFont: NSFont?
        private var paintedPalette: ThemePalette?

        init(document: EditorDocument, workspace: EditorWorkspace) {
            self.document = document
            self.workspace = workspace
        }

        /// Vim's keys on the view, while the setting is on.
        private(set) var vim: VimEngine?

        func setVim(enabled: Bool, in textView: NSTextView, scroll: NSScrollView) {
            guard let view = textView as? EditorNSTextView else { return }
            if enabled, vim == nil {
                let engine = VimEngine(buffer: TextViewVimBuffer(textView: textView))
                engine.onUndo = { [weak textView] in textView?.undoManager?.undo() }
                engine.onRedo = { [weak textView] in textView?.undoManager?.redo() }
                engine.onSave = { [weak self] in self?.workspace?.save() }
                engine.onQuit = { [weak self] in self?.workspace?.closeEditor() }
                vim = engine
                view.vim = engine
                view.onVimKey = { [weak self] in self?.workspace?.vimStatus = self?.vim?.status ?? "" }
                workspace?.vimStatus = engine.status
            } else if !enabled, vim != nil {
                vim = nil
                view.vim = nil
                view.onVimKey = nil
                workspace?.vimStatus = ""
                view.needsDisplay = true
            }
            if let vim {
                let height = scroll.contentView.bounds.height
                let line = (textView.font.map { $0.ascender - $0.descender + $0.leading }) ?? 16
                vim.pageLines = max(4, Int(height / max(line, 1)))
            }
        }

        func textDidChange(_ notification: Notification) {
            guard !isReplacingText, let textView else { return }
            document.replaceText(textView.string)
            ruler?.needsDisplay = true
            highlightSoon()
        }

        func textViewDidChangeSelection(_ notification: Notification) {
            ruler?.needsDisplay = true
        }

        /// Remembers what typing changed, shifted for later edits, so the
        /// next paint starts at the right line.
        func textStorage(_ textStorage: NSTextStorage, didProcessEditing editedMask: NSTextStorageEditActions,
                         range editedRange: NSRange, changeInLength delta: Int) {
            guard editedMask.contains(.editedCharacters), !isApplyingHighlight else { return }
            guard var range = pending else {
                pending = editedRange
                return
            }
            if range.location >= editedRange.location {
                range.location = max(editedRange.location, range.location + delta)
            } else if NSMaxRange(range) > editedRange.location {
                range.length = max(editedRange.location - range.location, range.length + delta)
            }
            let union = NSUnionRange(range, editedRange)
            let length = textStorage.length
            let location = min(union.location, length)
            pending = NSRange(location: location, length: min(union.length, length - location))
        }

        func appearanceChanged(font: NSFont?, palette: ThemePalette) {
            guard font != paintedFont || palette != paintedPalette else { return }
            let first = paintedPalette == nil
            paintedFont = font
            paintedPalette = palette
            paintsAll = true
            // The first paint is scheduled by makeNSView, after the text draws.
            if !first { highlightSoon() }
        }

        func highlightSoon(immediate: Bool = false) {
            if immediate { paintsAll = true }
            highlightWork?.cancel()
            let work = DispatchWorkItem { [weak self] in self?.applyHighlight() }
            highlightWork = work
            DispatchQueue.main.asyncAfter(deadline: .now() + (immediate ? 0 : 0.08), execute: work)
        }

        private func applyHighlight() {
            guard let textView, let storage = textView.textStorage,
                  let layout = textView.layoutManager else { return }
            let painter = SyntaxPainter(font: textView.font ?? .monospacedSystemFont(ofSize: 13, weight: .regular),
                                        palette: Theme.palette)
            isApplyingHighlight = true
            defer { isApplyingHighlight = false }
            let painted: NSRange
            if paintsAll || pending == nil {
                painter.paintAll(storage)
                painted = NSRange(location: 0, length: storage.length)
            } else {
                painted = painter.paint(storage, edited: pending!)
            }
            paintsAll = false
            pending = nil
            layout.invalidateDisplay(forCharacterRange: painted)
        }
    }
}

private final class EditorNSTextView: NSTextView {
    /// Vim's keys, when the setting is on; they take the keyboard first.
    var vim: VimEngine?
    var onVimKey: (() -> Void)?

    override func keyDown(with event: NSEvent) {
        (delegate as? CodeEditorTextView.Coordinator)?.live.finishTyping()
        if let vim, let key = VimKeys.name(for: event) {
            let before = vim.mode
            undoManager?.beginUndoGrouping()
            let used = vim.handle(key)
            undoManager?.endUndoGrouping()
            // Leaving Insert is a place for undo to stop.
            if before == .insert, vim.mode != .insert { breakUndoCoalescing() }
            onVimKey?()
            needsDisplay = true
            if used { return }
        }
        super.keyDown(with: event)
    }

    // A block over the character in Normal and Visual, a bar in Insert.
    private var blockWidth: CGFloat {
        guard let font else { return 8 }
        return max(font.maximumAdvancement.width, 6)
    }

    override func drawInsertionPoint(in rect: NSRect, color: NSColor, turnedOn flag: Bool) {
        guard let vim, vim.drawsBlockCaret else { return super.drawInsertionPoint(in: rect, color: color, turnedOn: flag) }
        var block = rect
        block.size.width = blockWidth
        super.drawInsertionPoint(in: block, color: color.withAlphaComponent(0.55), turnedOn: flag)
    }

    override func setNeedsDisplay(_ invalidRect: NSRect, avoidAdditionalLayout flag: Bool) {
        var rect = invalidRect
        if vim != nil { rect.size.width += blockWidth }
        super.setNeedsDisplay(rect, avoidAdditionalLayout: flag)
    }

    // Your own typing or click ends an agent's being typed in, so it never
    // waits for or fights it.
    override func mouseDown(with event: NSEvent) {
        (delegate as? CodeEditorTextView.Coordinator)?.live.finishTyping()
        super.mouseDown(with: event)
    }

    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        if event.modifierFlags.intersection(.deviceIndependentFlagsMask) == .command,
           event.charactersIgnoringModifiers == "s" {
            (delegate as? CodeEditorTextView.Coordinator)?.workspace?.save()
            return true
        }
        return super.performKeyEquivalent(with: event)
    }
}

/// A lightweight ruler backed by TextKit's laid-out line fragments. It only
/// draws the visible glyph range, so a large source file does not make scroll
/// events walk the whole document.
final class LineNumberRulerView: NSRulerView {
    weak var textView: NSTextView?
    var backgroundColor = NSColor.windowBackgroundColor
    var foregroundColor = NSColor.secondaryLabelColor
    var font = NSFont.monospacedSystemFont(ofSize: 12, weight: .regular)

    init(textView: NSTextView) {
        self.textView = textView
        super.init(scrollView: textView.enclosingScrollView, orientation: .verticalRuler)
        clientView = textView
        ruleThickness = 48
        NotificationCenter.default.addObserver(self, selector: #selector(redraw),
                                               name: NSView.boundsDidChangeNotification,
                                               object: textView.enclosingScrollView?.contentView)
    }

    required init(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
    deinit { NotificationCenter.default.removeObserver(self) }
    @objc private func redraw() { needsDisplay = true }

    override func drawHashMarksAndLabels(in rect: NSRect) {
        // Only the gutter: on current macOS `rect` is the whole scroll view's, and
        // filling all of it paints over the text.
        backgroundColor.setFill()
        NSRect(x: 0, y: rect.minY, width: ruleThickness, height: rect.height).fill()
        guard let textView, let layout = textView.layoutManager, let container = textView.textContainer else { return }
        let visible = scrollView?.contentView.bounds ?? .zero
        let glyphRange = layout.glyphRange(forBoundingRect: visible, in: container)
        let text = textView.string as NSString
        var line = 1
        if glyphRange.location > 0 {
            line += text.substring(to: min(glyphRange.location, text.length)).reduce(0) { $1 == "\n" ? $0 + 1 : $0 }
        }
        let paragraph = NSMutableParagraphStyle()
        paragraph.alignment = .right
        let attributes: [NSAttributedString.Key: Any] = [
            .font: font.withSize(max(9, font.pointSize - 1)),
            .foregroundColor: foregroundColor,
            .paragraphStyle: paragraph,
        ]
        layout.enumerateLineFragments(forGlyphRange: glyphRange) { [weak self] _, used, _, range, _ in
            guard let self else { return }
            let y = used.minY + textView.textContainerOrigin.y - visible.minY
            String(line).draw(in: NSRect(x: 4, y: y, width: ruleThickness - 11, height: used.height), withAttributes: attributes)
            line += 1
            if NSMaxRange(range) >= NSMaxRange(glyphRange) { return }
        }
        NSColor.separatorColor.setFill()
        NSRect(x: ruleThickness - 1, y: rect.minY, width: 1, height: rect.height).fill()
    }
}
