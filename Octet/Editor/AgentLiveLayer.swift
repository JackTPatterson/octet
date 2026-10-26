import AppKit
import SwiftUI

/// What the editor shows of an agent working in it, drawn over the text
/// view: a cursor with the agent's name where its edit is about to land,
/// the new text typed in as it arrives, the lines it changed lit in its
/// colour and fading, and the view following it. All of it is on top of
/// the buffer, never in it.
@MainActor
final class AgentLiveLayer {
    private weak var textView: NSTextView?
    private weak var scroll: NSScrollView?
    private let cursor = AgentCursorView()
    private let marks = AgentMarksView()
    private var presented: UUID?
    private var hideWork: DispatchWorkItem?
    private var typingTimer: Timer?
    private var typing: (location: Int, piece: NSString, typed: Int, perFrame: Int, final: String, edit: LiveEdit,
                         writer: AgentEditActivity.Writer?, ticks: Int)?
    private var restingPending: Int?
    /// Asked to repaint syntax colours while text is typed in, and when done.
    var repaint: (_ immediately: Bool) -> Void = { _ in }
    /// Typed text goes into the view's storage directly; this lets the
    /// coordinator know the text is no longer the document's.
    var typedText: (_ isTyping: Bool) -> Void = { _ in }

    private(set) var isTyping = false
    /// Settings › Show agent cursors. Off, edits still land, unadorned.
    var enabled = true

    private var reducedMotion: Bool { NSWorkspace.shared.accessibilityDisplayShouldReduceMotion }

    func attach(textView: NSTextView, scroll: NSScrollView) {
        self.textView = textView
        self.scroll = scroll
        marks.frame = textView.bounds
        marks.autoresizingMask = [.width, .height]
        textView.addSubview(marks)
    }

    // MARK: A change that landed

    /// Whether this change has already been shown.
    func hasShown(_ change: EditorDocument.LiveChange) -> Bool { presented == change.id }

    /// Whether the change can be typed in: the view still holds the old
    /// text, the new piece is short, and nothing asks for less motion.
    func canType(_ change: EditorDocument.LiveChange, current: String, final: String) -> Bool {
        guard enabled, !isTyping, !reducedMotion, NSApp.isActive, current == change.before,
              change.edit.newRange.length > 0, change.edit.newRange.length <= 1_800, change.edit.oldRange.length <= 4_000,
              (final as NSString).length < 400_000 else { return false }
        return true
    }

    /// Shows a change that has been applied all at once: its lines lit and
    /// the cursor gliding to where the agent stopped.
    func present(_ change: EditorDocument.LiveChange, follow: Bool) {
        guard presented != change.id else { return }
        presented = change.id
        guard enabled else { return }
        flash(change.edit.hunks, writer: change.writer)
        place(at: change.edit.cursor, writer: change.writer, doing: "Edited", animated: true, follow: follow, blinking: true)
        scheduleHide(after: 3.5)
    }

    /// Types the new text in where the old was, after taking the old out.
    func type(_ change: EditorDocument.LiveChange, final: String, follow: Bool) {
        guard let textView, let storage = textView.textStorage else { return }
        presented = change.id
        isTyping = true
        typedText(true)
        hideWork?.cancel()
        let edit = change.edit
        let piece = (final as NSString).substring(with: edit.newRange) as NSString
        storage.replaceCharacters(in: edit.oldRange, with: "")
        let frames = min(48, max(8, piece.length / 3))
        let perFrame = max(1, Int((Double(piece.length) / Double(frames)).rounded(.up)))
        typing = (edit.newRange.location, piece, 0, perFrame, final, edit, change.writer, 0)
        place(at: edit.newRange.location, writer: change.writer, doing: "Typing", animated: false, follow: follow, blinking: false)
        typingTimer?.invalidate()
        typingTimer = Timer.scheduledTimer(withTimeInterval: 1.0 / 60.0, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.typeNextChunk(follow: follow) }
        }
    }

    private func typeNextChunk(follow: Bool) {
        guard var state = typing, let textView, let storage = textView.textStorage else { return finishTyping() }
        var end = min(state.typed + state.perFrame, state.piece.length)
        if end < state.piece.length, end > state.typed, UTF16.isLeadSurrogate(state.piece.character(at: end - 1)) { end += 1 }
        let chunk = state.piece.substring(with: NSRange(location: state.typed, length: end - state.typed))
        storage.replaceCharacters(in: NSRange(location: state.location + state.typed, length: 0), with: chunk)
        state.typed = end
        state.ticks += 1
        typing = state
        place(at: state.location + state.typed, writer: state.writer, doing: "Typing", animated: false, follow: follow, blinking: false)
        if state.ticks % 8 == 0 { repaint(false) }
        if state.typed >= state.piece.length { finishTyping() }
    }

    /// Puts whatever is left in at once, and settles. Also what a key press
    /// or a click does: typing along with the agent isn't a thing to wait for.
    func finishTyping() {
        guard isTyping, let textView else { return }
        typingTimer?.invalidate()
        typingTimer = nil
        let state = typing
        typing = nil
        if let state, textView.string != state.final {
            let selection = textView.selectedRange()
            textView.string = state.final
            textView.setSelectedRange(NSRange(location: min(selection.location, (state.final as NSString).length), length: 0))
        }
        isTyping = false
        typedText(false)
        repaint(true)
        if let state {
            flash(state.edit.hunks, writer: state.writer)
            place(at: state.edit.cursor, writer: state.writer, doing: "Edited", animated: true, follow: false, blinking: true)
            scheduleHide(after: 3.5)
        }
    }

    // MARK: An edit about to land

    /// Parks the cursor where an edit that's started will land, breathing,
    /// or takes it away when there's none.
    func showPending(at location: Int?, writer: AgentEditActivity.Writer?, follow: Bool) {
        guard !isTyping else { return }
        guard enabled, let location, let writer else {
            if restingPending != nil { restingPending = nil; hide() }
            return
        }
        guard restingPending != location else { return }
        restingPending = location
        hideWork?.cancel()
        place(at: location, writer: writer, doing: "Editing", animated: true, follow: follow, blinking: true)
    }

    // MARK: Drawing

    private func place(at index: Int, writer: AgentEditActivity.Writer?, doing: String, animated: Bool, follow: Bool, blinking: Bool) {
        guard let textView, let rect = caretRect(at: index) else { return }
        let hue = Self.color(hex: writer?.hueHex)
        cursor.configure(name: writer?.name ?? "Agent", doing: doing, hue: hue, caret: rect)
        let appearing = cursor.superview == nil || cursor.alphaValue < 0.01
        if cursor.superview == nil { textView.addSubview(cursor) }
        let frame = cursor.frame(forCaret: rect)
        cursor.isHidden = false
        if animated, !reducedMotion, !appearing {
            // Glides with the same curve and a length that follows the distance.
            let distance = hypot(frame.minX - cursor.frame.minX, frame.minY - cursor.frame.minY)
            NSAnimationContext.runAnimationGroup { context in
                context.duration = min(0.56, 0.2 + Double(distance) / 1_100)
                context.timingFunction = CAMediaTimingFunction(controlPoints: 0.32, 0.72, 0.24, 1)
                cursor.animator().frame = frame
            }
        } else {
            cursor.frame = frame
            if appearing, !reducedMotion {
                cursor.alphaValue = 0
                NSAnimationContext.runAnimationGroup { context in
                    context.duration = 0.26
                    cursor.animator().alphaValue = 1
                }
            } else {
                cursor.alphaValue = 1
            }
        }
        cursor.setBlinking(blinking && !reducedMotion)
        cursor.revealFlag(for: 2.2, animated: !reducedMotion)
        if follow { reveal(rect) }
    }

    private func hide() {
        cursor.setBlinking(false)
        guard cursor.superview != nil else { return }
        NSAnimationContext.runAnimationGroup({ context in
            context.duration = reducedMotion ? 0 : 0.3
            cursor.animator().alphaValue = 0
        })
    }

    private func scheduleHide(after seconds: TimeInterval) {
        hideWork?.cancel()
        let work = DispatchWorkItem { [weak self] in MainActor.assumeIsolated { self?.hide() } }
        hideWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + seconds, execute: work)
    }

    private func flash(_ hunks: [NSRange], writer: AgentEditActivity.Writer?) {
        guard let textView, let layout = textView.layoutManager, let container = textView.textContainer else { return }
        let origin = textView.textContainerOrigin
        var rects: [NSRect] = []
        let length = (textView.string as NSString).length
        for hunk in hunks where hunk.length > 0 && NSMaxRange(hunk) <= length {
            let glyphs = layout.glyphRange(forCharacterRange: hunk, actualCharacterRange: nil)
            layout.enumerateEnclosingRects(forGlyphRange: glyphs, withinSelectedGlyphRange: NSRange(location: NSNotFound, length: 0),
                                           in: container) { rect, _ in
                rects.append(rect.offsetBy(dx: origin.x, dy: origin.y))
            }
        }
        marks.flash(rects, hue: Self.color(hex: writer?.hueHex), animated: !reducedMotion)
    }

    /// Brings `rect` into view, easing there, when it's near or past an edge.
    private func reveal(_ rect: NSRect) {
        guard let scroll, let textView else { return }
        let clip = scroll.contentView
        let visible = clip.bounds
        let margin: CGFloat = 70
        if rect.minY >= visible.minY + margin, rect.maxY <= visible.maxY - margin { return }
        let y = max(0, min(rect.midY - visible.height * 0.38, textView.frame.height - visible.height))
        NSAnimationContext.runAnimationGroup { context in
            context.duration = reducedMotion ? 0 : 0.35
            context.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
            clip.animator().setBoundsOrigin(NSPoint(x: visible.minX, y: y))
        }
        scroll.reflectScrolledClipView(clip)
    }

    /// The insertion point's place at a character offset, in the text view's coordinates.
    private func caretRect(at index: Int) -> NSRect? {
        guard let textView, let layout = textView.layoutManager, let container = textView.textContainer else { return nil }
        let text = textView.string as NSString
        let origin = textView.textContainerOrigin
        let font = textView.font ?? .monospacedSystemFont(ofSize: 13, weight: .regular)
        let lineHeight = ceil(font.ascender - font.descender + font.leading)
        if text.length == 0 {
            return NSRect(x: origin.x + container.lineFragmentPadding, y: origin.y, width: 2, height: lineHeight)
        }
        let clamped = min(max(index, 0), text.length)
        layout.ensureLayout(forCharacterRange: NSRange(location: max(0, clamped - 1), length: min(2, text.length - max(0, clamped - 1))))
        if clamped == text.length {
            if text.hasSuffix("\n") {
                let extra = layout.extraLineFragmentRect
                return NSRect(x: origin.x + extra.minX + container.lineFragmentPadding, y: origin.y + extra.minY,
                              width: 2, height: extra.height > 0 ? extra.height : lineHeight)
            }
            let glyph = max(layout.numberOfGlyphs - 1, 0)
            let line = layout.lineFragmentUsedRect(forGlyphAt: glyph, effectiveRange: nil)
            let box = layout.boundingRect(forGlyphRange: NSRange(location: glyph, length: 1), in: container)
            return NSRect(x: origin.x + box.maxX, y: origin.y + line.minY, width: 2, height: line.height)
        }
        let glyph = layout.glyphIndexForCharacter(at: clamped)
        let line = layout.lineFragmentUsedRect(forGlyphAt: glyph, effectiveRange: nil)
        let fragment = layout.lineFragmentRect(forGlyphAt: glyph, effectiveRange: nil)
        let location = layout.location(forGlyphAt: glyph)
        return NSRect(x: origin.x + fragment.minX + location.x, y: origin.y + line.minY, width: 2, height: line.height)
    }

    static func color(hex: String?) -> NSColor {
        if let hex { return NSColor(Color(hex: hex)) }
        return Theme.palette.nsColor(\.accent)
    }
}

/// The agent's cursor, drawn like a teammate's in a multiplayer editor: a
/// blinking caret in its colour, a soft pointer resting at it, and a flag at
/// the pointer's lower right with its name and what it's doing. The flag
/// shows while it acts and steps aside when it's still.
private final class AgentCursorView: NSView {
    private let caret = NSView()
    private let pointer = AgentPointerView()
    private let flag = AgentFlagView()
    private var caretHeight: CGFloat = 16
    private var hideFlagWork: DispatchWorkItem?

    override var isFlipped: Bool { true }
    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        caret.wantsLayer = true
        caret.layer?.cornerRadius = 1
        addSubview(caret)
        addSubview(pointer)
        addSubview(flag)
    }

    required init?(coder: NSCoder) { fatalError() }

    func configure(name: String, doing: String, hue: NSColor, caret rect: NSRect) {
        caretHeight = rect.height
        caret.layer?.backgroundColor = hue.cgColor
        caret.frame = NSRect(x: 0, y: 0, width: 2, height: rect.height)
        pointer.hue = hue
        pointer.frame = NSRect(x: -2, y: rect.height - 3, width: AgentPointerView.size.width + 4, height: AgentPointerView.size.height + 4)
        flag.configure(name: name, doing: doing)
        flag.frame.origin = NSPoint(x: 13, y: rect.height + 7)
    }

    /// Where the view sits for a caret rect; the flag's room is in its height.
    func frame(forCaret rect: NSRect) -> NSRect {
        NSRect(x: rect.minX, y: rect.minY, width: max(flag.frame.maxX, 20), height: flag.frame.maxY)
    }

    /// Shows the flag, and takes it away again after a moment.
    func revealFlag(for seconds: TimeInterval, animated: Bool) {
        hideFlagWork?.cancel()
        flag.setShown(true, animated: animated)
        let work = DispatchWorkItem { [weak self] in
            MainActor.assumeIsolated { self?.flag.setShown(false, animated: animated) }
        }
        hideFlagWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + seconds, execute: work)
    }

    /// The caret blinks when the agent is idle or waiting, and holds still
    /// while it types.
    func setBlinking(_ blinking: Bool) {
        guard let layer = caret.layer else { return }
        if blinking {
            guard layer.animation(forKey: "blink") == nil else { return }
            let blink = CAKeyframeAnimation(keyPath: "opacity")
            blink.values = [1, 0]
            blink.keyTimes = [0, 0.5]
            blink.calculationMode = .discrete
            blink.duration = 1.1
            blink.repeatCount = .infinity
            layer.add(blink, forKey: "blink")
        } else {
            layer.removeAnimation(forKey: "blink")
        }
    }
}

/// The soft rounded pointer, filled in the agent's colour with a white edge.
private final class AgentPointerView: NSView {
    static let size = NSSize(width: 16, height: 19)
    var hue = NSColor.systemPurple { didSet { needsDisplay = true } }

    override var isFlipped: Bool { true }
    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    override func draw(_ dirtyRect: NSRect) {
        // The 20 x 24 arrow of the Browser plane's cursor, scaled to fit.
        let scale: CGFloat = 0.8
        let points: [(CGFloat, CGFloat)] = [(3, 2.4), (3, 18.4), (7.2, 14.6), (9.9, 20.9), (13, 19.6), (10.3, 13.4), (15.9, 13.1)]
        let path = NSBezierPath()
        for (index, point) in points.enumerated() {
            // The arrow's tip (3, 2.4) lands at (4, 4) in this view.
            let place = NSPoint(x: 4 + (point.0 - 3) * scale, y: 4 + (point.1 - 2.4) * scale)
            index == 0 ? path.move(to: place) : path.line(to: place)
        }
        path.close()
        path.lineJoinStyle = .round
        NSGraphicsContext.saveGraphicsState()
        let shadow = NSShadow()
        shadow.shadowColor = NSColor.black.withAlphaComponent(0.35)
        shadow.shadowBlurRadius = 3
        shadow.shadowOffset = NSSize(width: 0, height: -1.5)
        shadow.set()
        hue.setFill()
        path.fill()
        NSGraphicsContext.restoreGraphicsState()
        NSColor.white.setStroke()
        path.lineWidth = 1.3
        path.stroke()
    }
}

/// The flag: a card with the agent's name and what it's doing, edged in a
/// pink-to-blue gradient with a soft glow. Light on a dark editor, dark on
/// a light one.
private final class AgentFlagView: NSView {
    private var name = ""
    private var doing = ""
    private static let nameFont = NSFont.systemFont(ofSize: 11.5, weight: .semibold)
    private static let doingFont = NSFont.systemFont(ofSize: 11, weight: .regular)

    override var isFlipped: Bool { true }
    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        alphaValue = 0
        layer?.masksToBounds = false
        layer?.shadowColor = NSColor(calibratedRed: 0.55, green: 0.42, blue: 1, alpha: 1).cgColor
        layer?.shadowOpacity = 0.4
        layer?.shadowRadius = 9
        layer?.shadowOffset = CGSize(width: 0, height: -5)
    }

    required init?(coder: NSCoder) { fatalError() }

    func configure(name: String, doing: String) {
        self.name = name
        self.doing = doing
        let nameWidth = (name as NSString).size(withAttributes: [.font: Self.nameFont]).width
        let doingWidth = doing.isEmpty ? 0 : (doing as NSString).size(withAttributes: [.font: Self.doingFont]).width
        let width = ceil(max(nameWidth, doingWidth)) + 20
        setFrameSize(NSSize(width: width, height: doing.isEmpty ? 24 : 38))
        needsDisplay = true
    }

    func setShown(_ shown: Bool, animated: Bool) {
        let target: CGFloat = shown ? 1 : 0
        guard alphaValue != target else { return }
        if animated {
            NSAnimationContext.runAnimationGroup { context in
                context.duration = shown ? 0.2 : 0.35
                animator().alphaValue = target
            }
        } else {
            alphaValue = target
        }
    }

    override func draw(_ dirtyRect: NSRect) {
        let outer = NSBezierPath(roundedRect: bounds, xRadius: 8, yRadius: 8)
        let gradient = NSGradient(colors: [NSColor(calibratedRed: 1, green: 0.31, blue: 0.64, alpha: 1),
                                           NSColor(calibratedRed: 0.55, green: 0.42, blue: 1, alpha: 1),
                                           NSColor(calibratedRed: 0.23, green: 0.55, blue: 1, alpha: 1)],
                                  atLocations: [0, 0.55, 1], colorSpace: .sRGB)
        gradient?.draw(in: outer, angle: 0)
        let light = !Theme.isLight
        let card = light ? NSColor(srgbRed: 0.957, green: 0.957, blue: 0.961, alpha: 1) : NSColor(srgbRed: 0.11, green: 0.11, blue: 0.122, alpha: 1)
        card.setFill()
        NSBezierPath(roundedRect: bounds.insetBy(dx: 1.5, dy: 1.5), xRadius: 6.5, yRadius: 6.5).fill()
        let primary = light ? NSColor(srgbRed: 0.078, green: 0.078, blue: 0.086, alpha: 1) : NSColor(srgbRed: 0.957, green: 0.957, blue: 0.961, alpha: 1)
        (name as NSString).draw(at: NSPoint(x: 10, y: 4), withAttributes: [.font: Self.nameFont, .foregroundColor: primary])
        if !doing.isEmpty {
            (doing as NSString).draw(at: NSPoint(x: 10, y: 20), withAttributes: [.font: Self.doingFont,
                                                                                  .foregroundColor: primary.withAlphaComponent(0.55)])
        }
    }
}

/// The lines an edit changed, lit in the agent's colour, then fading.
private final class AgentMarksView: NSView {
    override var isFlipped: Bool { true }
    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        layer?.masksToBounds = false
    }

    required init?(coder: NSCoder) { fatalError() }

    func flash(_ rects: [NSRect], hue: NSColor, animated: Bool) {
        guard let host = layer else { return }
        for rect in rects.prefix(60) {
            let mark = CALayer()
            mark.frame = rect.insetBy(dx: -3, dy: -0.5)
            mark.cornerRadius = 3
            mark.backgroundColor = hue.withAlphaComponent(0.24).cgColor
            host.addSublayer(mark)
            guard animated else {
                DispatchQueue.main.asyncAfter(deadline: .now() + 1.2) { mark.removeFromSuperlayer() }
                continue
            }
            let fade = CABasicAnimation(keyPath: "opacity")
            fade.fromValue = 1
            fade.toValue = 0
            fade.duration = 2.2
            fade.beginTime = CACurrentMediaTime() + 0.6
            fade.fillMode = .both
            fade.timingFunction = CAMediaTimingFunction(name: .easeIn)
            mark.opacity = 0
            mark.add(fade, forKey: "fade")
            DispatchQueue.main.asyncAfter(deadline: .now() + 3.2) { mark.removeFromSuperlayer() }
        }
    }
}
