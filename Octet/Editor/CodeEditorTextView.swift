import AppKit
import SwiftUI

/// AppKit's text system supplies the editor mechanics that should feel native:
/// selection, undo, IME input, Services, drag/drop and the system find bar.
/// SwiftUI owns the surrounding file UI; this view only owns the buffer.
struct CodeEditorTextView: NSViewRepresentable {
    @ObservedObject var document: EditorDocument
    @ObservedObject private var settings = SettingsStore.shared
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
        if textView.string != document.text, !context.coordinator.isApplyingHighlight {
            let selection = textView.selectedRanges
            context.coordinator.isReplacingText = true
            textView.string = document.text
            textView.selectedRanges = selection.compactMap { value in
                let range = value.rangeValue
                return NSValue(range: NSRange(location: min(range.location, document.text.utf16.count), length: 0))
            }
            context.coordinator.isReplacingText = false
            context.coordinator.highlightSoon(immediate: true)
        }
    }

    private func applyAppearance(to textView: NSTextView, scroll: NSScrollView, ruler: LineNumberRulerView?) {
        let palette = Theme.palette
        let background = palette.nsColor(\.background)
        let family = settings.values.fontFamily
        let editorFont: NSFont = family.isEmpty
            ? .monospacedSystemFont(ofSize: settings.values.fontSize, weight: .regular)
            : NSFont(name: family, size: settings.values.fontSize) ?? .monospacedSystemFont(ofSize: settings.values.fontSize, weight: .regular)
        textView.font = editorFont
        textView.textColor = palette.nsColor(\.textPrimary)
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
