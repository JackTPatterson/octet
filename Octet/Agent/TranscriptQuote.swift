import AppKit
import SwiftUI

// MARK: - What transcript rows can ask of the conversation

/// What a row in the transcript can do beyond itself: quote into the
/// composer, open a turn's diff or a file, show a command's whole output.
/// Rows are Equatable and hold no session, so these come down the
/// environment from the transcript.
struct TranscriptActions {
    var cwd: String?
    var quote: (String, TranscriptQuote.Action) -> Void = { _, _ in }
    var openTurnDiff: (TurnChanges, String?) -> Void = { _, _ in }
    var openFile: (String) -> Void = { _ in }
    var openOutput: (String) -> Void = { _ in }
}

private struct TranscriptActionsKey: EnvironmentKey {
    static let defaultValue = TranscriptActions()
}

extension EnvironmentValues {
    var transcriptActions: TranscriptActions {
        get { self[TranscriptActionsKey.self] }
        set { self[TranscriptActionsKey.self] = newValue }
    }
}

// MARK: - Selection in a reply

/// Text selected in a reply, and where the pointer let go, in the reply's
/// own coordinates (top-left origin).
struct AssistantSelection: Equatable {
    let text: String
    let point: CGPoint
}

/// Watches for a selection made inside the view it sits over. SwiftUI's
/// selectable text has no selection API on macOS, but the text view that
/// holds one answers the Services protocol, so the selection is read onto a
/// private pasteboard (never the clipboard) once the pointer lets go.
struct SelectionWatcher: NSViewRepresentable {
    let onChange: (AssistantSelection?) -> Void

    func makeNSView(context: Context) -> WatcherView {
        let view = WatcherView()
        view.onChange = onChange
        return view
    }

    func updateNSView(_ view: WatcherView, context: Context) {
        view.onChange = onChange
    }

    static func dismantleNSView(_ view: WatcherView, coordinator: ()) {
        view.stop()
    }

    final class WatcherView: NSView {
        var onChange: (AssistantSelection?) -> Void = { _ in }
        private var monitor: Any?
        private var showing = false
        private static let pasteboard = NSPasteboard(name: NSPasteboard.Name("com.jpxsoftware.octet.transcript-selection"))

        override var isFlipped: Bool { true }
        override func hitTest(_ point: NSPoint) -> NSView? { nil }

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            if window == nil { stop() } else if monitor == nil { start() }
        }

        private func start() {
            monitor = NSEvent.addLocalMonitorForEvents(matching: [.leftMouseDown, .leftMouseUp]) { [weak self] event in
                self?.handle(event)
                return event
            }
        }

        func stop() {
            if let monitor { NSEvent.removeMonitor(monitor) }
            monitor = nil
        }

        private func handle(_ event: NSEvent) {
            guard let window, event.window === window else { return }
            let point = convert(event.locationInWindow, from: nil)
            let inside = bounds.contains(point)
            switch event.type {
            // The bar may sit just past the reply's edge; a press on it
            // mustn't take it away before its button fires.
            case .leftMouseDown where !bounds.insetBy(dx: 0, dy: -44).contains(point):
                report(nil)
            case .leftMouseUp where inside:
                // After the event lands, so the text view has settled its selection.
                DispatchQueue.main.async { [weak self] in self?.read(at: point) }
            default:
                break
            }
        }

        private func read(at point: CGPoint) {
            guard let responder = window?.firstResponder as? NSView,
                  let requestor = responder as? NSServicesMenuRequestor,
                  bounds.intersects(convert(responder.bounds, from: responder)) else { return report(nil) }
            let board = Self.pasteboard
            board.clearContents()
            guard requestor.writeSelection?(to: board, types: [.string]) == true,
                  let text = board.string(forType: .string),
                  !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return report(nil) }
            board.clearContents()
            report(AssistantSelection(text: text, point: point))
        }

        private func report(_ selection: AssistantSelection?) {
            guard selection != nil || showing else { return }
            showing = selection != nil
            onChange(selection)
        }
    }
}

/// The small floating bar over a selection in a reply, after T3 Code's
/// selection toolbar: quote the passage into the composer, copy it, or
/// quote it with a question started.
struct AssistantSelectionToolbar: View {
    let selection: AssistantSelection
    let quote: (TranscriptQuote.Action) -> Void
    let dismiss: () -> Void

    var body: some View {
        HStack(spacing: 2) {
            OctetButton(title: "Quote", icon: "quote.opening", kind: .ghost, compact: true) { quote(.quote) }
                .help("Quote this passage in the message you're writing")
            OctetButton(title: "Copy", icon: "doc.on.doc", kind: .ghost, compact: true) {
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(selection.text, forType: .string)
                ToastCenter.shared.info("Copied the selection")
                dismiss()
            }
            OctetButton(title: "Ask about this", icon: "text.bubble", kind: .ghost, compact: true) { quote(.ask) }
                .help("Quote this passage and start a question about it")
        }
        .padding(3)
        .octetGlass(cornerRadius: 10)
        .shadow(color: .black.opacity(0.25), radius: 8, y: 3)
        .fixedSize()
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Selection actions")
    }

    /// Where the bar goes for a selection ending at `point` in a reply
    /// `size` big: just under the pointer, kept inside the reply, flipped
    /// above near its bottom.
    static func origin(for point: CGPoint, in size: CGSize, toolbar: CGSize = CGSize(width: 260, height: 32)) -> CGPoint {
        let x = min(max(0, point.x - toolbar.width / 2), max(0, size.width - toolbar.width))
        let below = point.y + 12
        let y = below + toolbar.height <= size.height + 40 ? below : point.y - toolbar.height - 12
        return CGPoint(x: x, y: y)
    }
}
