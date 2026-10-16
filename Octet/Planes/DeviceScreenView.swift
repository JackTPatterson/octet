import AppKit
import SwiftUI

/// The device's live screen. AppKit rather than a SwiftUI Image: a frame
/// only swaps a layer's contents, and the view gets the raw mouse, scroll
/// and key events input needs.
struct DeviceScreenView: View {
    @ObservedObject var frames: DeviceFrameStore
    let tablet: Bool
    let interactive: Bool
    let send: (DeviceInput) -> Void
    let type: (String) -> Void

    var body: some View {
        DeviceScreenRepresentable(image: frames.image, tablet: tablet, interactive: interactive,
                                  border: NSColor(Theme.border), focus: NSColor(Theme.accent),
                                  send: send, type: type)
            .accessibilityElement()
            .accessibilityLabel("Device screen")
            .accessibilityHint(interactive ? "Click to tap, drag to swipe, and type while it's focused." : "")
    }
}

private struct DeviceScreenRepresentable: NSViewRepresentable {
    let image: CGImage?
    let tablet: Bool
    let interactive: Bool
    let border: NSColor
    let focus: NSColor
    let send: (DeviceInput) -> Void
    let type: (String) -> Void

    func makeNSView(context: Context) -> DeviceScreenNSView { DeviceScreenNSView() }

    func updateNSView(_ view: DeviceScreenNSView, context: Context) {
        view.tablet = tablet
        view.interactive = interactive
        view.borderColor = border
        view.focusColor = focus
        view.send = send
        view.type = type
        view.show(image)
    }
}

final class DeviceScreenNSView: NSView {
    var tablet = false
    var interactive = true
    var borderColor = NSColor.white.withAlphaComponent(0.12) { didSet { updateBorder() } }
    var focusColor = NSColor.controlAccentColor { didSet { updateBorder() } }
    var send: (DeviceInput) -> Void = { _ in }
    var type: (String) -> Void = { _ in }

    private let screen = CALayer()
    private var imageSize: CGSize = .zero
    private var dragStart: (point: CGPoint, normalized: CGPoint, time: Date)?
    private var dragLast: CGPoint?
    private var scrollDelta: CGSize = .zero
    private var scrollOrigin: CGPoint?
    private var scrollFlush: DispatchWorkItem?
    private var focused = false { didSet { updateBorder() } }

    /// A press that moves less than this is a tap; more is a swipe.
    static let tapSlop: CGFloat = 6

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        layer?.masksToBounds = false
        screen.masksToBounds = true
        screen.contentsGravity = .resize
        screen.borderWidth = 1
        screen.backgroundColor = NSColor.black.cgColor
        screen.minificationFilter = .trilinear
        screen.magnificationFilter = .linear
        layer?.addSublayer(screen)
    }

    required init?(coder: NSCoder) { nil }

    override var isFlipped: Bool { true }
    override var acceptsFirstResponder: Bool { interactive }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    func show(_ image: CGImage?) {
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        screen.contents = image
        let size = image.map { CGSize(width: $0.width, height: $0.height) } ?? .zero
        if size != imageSize {
            imageSize = size
            needsLayout = true
        }
        screen.isHidden = image == nil
        CATransaction.commit()
    }

    override func layout() {
        super.layout()
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        let rect = DeviceHub.fit(imageSize, in: bounds.size)
        screen.frame = rect
        screen.cornerRadius = DeviceHub.cornerRadius(for: rect.size, tablet: tablet)
        CATransaction.commit()
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        updateBorder()
    }

    private func updateBorder() {
        screen.borderColor = (focused ? focusColor.withAlphaComponent(0.6) : borderColor).cgColor
    }

    private func normalized(_ event: NSEvent) -> (CGPoint, CGPoint?) {
        let point = convert(event.locationInWindow, from: nil)
        return (point, DeviceHub.normalized(point, in: bounds.size, screen: imageSize))
    }

    // MARK: Pointer

    override func mouseDown(with event: NSEvent) {
        guard interactive else { return }
        window?.makeFirstResponder(self)
        let (point, spot) = normalized(event)
        guard let spot else { return }
        dragStart = (point, spot, Date())
        dragLast = point
    }

    override func mouseDragged(with event: NSEvent) {
        guard dragStart != nil else { return }
        dragLast = convert(event.locationInWindow, from: nil)
    }

    override func mouseUp(with event: NSEvent) {
        guard let start = dragStart else { return }
        dragStart = nil
        let (point, spot) = normalized(event)
        let distance = hypot(point.x - start.point.x, point.y - start.point.y)
        if distance < Self.tapSlop {
            send(.tap(start.normalized))
        } else {
            // A swipe that leaves the screen ends at its edge.
            let rect = DeviceHub.fit(imageSize, in: bounds.size)
            let end = spot ?? CGPoint(x: min(1, max(0, (point.x - rect.minX) / max(rect.width, 1))),
                                      y: min(1, max(0, (point.y - rect.minY) / max(rect.height, 1))))
            let duration = min(1, max(0.1, Date().timeIntervalSince(start.time)))
            send(.swipe(from: start.normalized, to: end, duration: duration))
        }
    }

    /// Scrolling gathers for a moment, then goes as one swipe from where
    /// the pointer is, so a trackpad's stream of small deltas isn't dozens
    /// of tiny swipes.
    override func scrollWheel(with event: NSEvent) {
        guard interactive else { return super.scrollWheel(with: event) }
        let (_, spot) = normalized(event)
        guard let spot else { return }
        if scrollOrigin == nil { scrollOrigin = spot }
        let scale: CGFloat = event.hasPreciseScrollingDeltas ? 1 : 12
        scrollDelta.width += event.scrollingDeltaX * scale
        scrollDelta.height += event.scrollingDeltaY * scale
        scrollFlush?.cancel()
        let work = DispatchWorkItem { [weak self] in self?.flushScroll() }
        scrollFlush = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.12, execute: work)
    }

    private func flushScroll() {
        defer { scrollDelta = .zero; scrollOrigin = nil }
        let rect = DeviceHub.fit(imageSize, in: bounds.size)
        guard let origin = scrollOrigin,
              let swipe = DeviceHub.scrollSwipe(delta: scrollDelta, from: origin, viewSize: rect.size) else { return }
        send(.swipe(from: swipe.from, to: swipe.to, duration: 0.25))
    }

    // MARK: Keys

    override func becomeFirstResponder() -> Bool {
        focused = true
        return true
    }

    override func resignFirstResponder() -> Bool {
        focused = false
        return true
    }

    override func keyDown(with event: NSEvent) {
        guard interactive else { return super.keyDown(with: event) }
        // Octet's own shortcuts still work while the screen has focus.
        if event.modifierFlags.contains(.command) { return super.keyDown(with: event) }
        let key: DeviceKey? = switch event.keyCode {
        case 36, 76: .enter
        case 51: .delete
        case 48: .tab
        case 53: .escape
        case 123: .left
        case 124: .right
        case 125: .down
        case 126: .up
        default: nil
        }
        if let key {
            send(.key(key))
            return
        }
        guard let characters = event.characters, !characters.isEmpty,
              characters.unicodeScalars.allSatisfy({ !CharacterSet.controlCharacters.contains($0) && $0.value < 0xF700 })
        else { return super.keyDown(with: event) }
        type(characters)
    }
}
