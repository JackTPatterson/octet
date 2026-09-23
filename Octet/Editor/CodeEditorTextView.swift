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
        // Start from AppKit's canonical text-system stack. Hand-assembling an
        // NSTextView and then installing it as an NSScrollView document view
        // can leave TextKit laying out glyphs in a stale, offscreen container.
        let scroll = EditorNSTextView.scrollableTextView()
        guard let textView = scroll.documentView as? EditorNSTextView else {
            preconditionFailure("NSTextView.scrollableTextView returned an unexpected document view")
        }
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
    final class Coordinator: NSObject, NSTextViewDelegate {
        var document: EditorDocument
        weak var workspace: EditorWorkspace?
        weak var textView: NSTextView?
        weak var ruler: LineNumberRulerView?
        var isReplacingText = false
        var isApplyingHighlight = false
        private var highlightWork: DispatchWorkItem?

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

        func highlightSoon(immediate: Bool = false) {
            highlightWork?.cancel()
            let work = DispatchWorkItem { [weak self] in self?.applyHighlight() }
            highlightWork = work
            DispatchQueue.main.asyncAfter(deadline: .now() + (immediate ? 0 : 0.08), execute: work)
        }

        private func applyHighlight() {
            guard let textView, let storage = textView.textStorage,
                  let layout = textView.layoutManager,
                  let container = textView.textContainer else { return }
            let string = textView.string
            let palette = Theme.palette
            let full = NSRange(location: 0, length: (string as NSString).length)
            let font = textView.font ?? .monospacedSystemFont(ofSize: 13, weight: .regular)
            isApplyingHighlight = true
            storage.beginEditing()
            storage.setAttributes([
                .font: font,
                .foregroundColor: palette.nsColor(\.textPrimary),
            ], range: full)
            var state = CodeHighlighter.State()
            var utf16Offset = 0
            string.enumerateLines { line, _ in
                for span in CodeHighlighter.highlight(line, state: &state) {
                    let length = (span.text as NSString).length
                    let color: NSColor
                    switch span.kind {
                    case .plain: color = palette.nsColor(\.textPrimary)
                    case .keyword: color = palette.nsColor(\.syntaxFlag)
                    case .type: color = palette.nsColor(\.syntaxBuiltin)
                    case .string: color = palette.nsColor(\.syntaxString)
                    case .comment: color = palette.nsColor(\.textTertiary)
                    case .number: color = palette.nsColor(\.syntaxVariable)
                    }
                    storage.addAttribute(.foregroundColor, value: color,
                                         range: NSRange(location: utf16Offset, length: length))
                    utf16Offset += length
                }
                // enumerateLines omits the line ending.
                if utf16Offset < full.length { utf16Offset += 1 }
            }
            storage.endEditing()
            layout.invalidateDisplay(forCharacterRange: full)
            layout.ensureLayout(for: container)
            textView.needsDisplay = true
            isApplyingHighlight = false
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
        backgroundColor.setFill()
        rect.fill()
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
