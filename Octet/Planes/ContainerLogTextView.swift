import AppKit
import SwiftUI

/// Selectable, unwrapped output with independent horizontal and vertical scrolling.
struct ContainerLogTextView: NSViewRepresentable {
    let logs: String
    let follow: Bool

    final class Coordinator {
        var rendered: NSAttributedString?
        var started = false
    }
    func makeCoordinator() -> Coordinator { Coordinator() }

    func makeNSView(context: Context) -> NSScrollView {
        let scroll = ContainerLogScrollView()
        scroll.hasVerticalScroller = true
        scroll.hasHorizontalScroller = true
        scroll.drawsBackground = false
        let text = NSTextView()
        text.isEditable = false
        text.isSelectable = true
        text.drawsBackground = false
        text.textContainerInset = NSSize(width: 12, height: 12)
        text.isHorizontallyResizable = true
        text.isVerticallyResizable = true
        text.autoresizingMask = []
        text.maxSize = NSSize(width: CGFloat.greatestFiniteMagnitude, height: CGFloat.greatestFiniteMagnitude)
        text.textContainer?.containerSize = text.maxSize
        text.textContainer?.widthTracksTextView = false
        scroll.documentView = text
        return scroll
    }

    func updateNSView(_ scroll: NSScrollView, context: Context) {
        (scroll as? ContainerLogScrollView)?.follow = follow
        guard let text = scroll.documentView as? NSTextView else { return }
        let rendered = ContainerLogColors.render(logs)
        guard context.coordinator.rendered != rendered else { return }
        let origin = scroll.contentView.bounds.origin
        let first = !context.coordinator.started && !logs.isEmpty
        context.coordinator.started = context.coordinator.started || !logs.isEmpty
        context.coordinator.rendered = rendered
        text.textStorage?.setAttributedString(rendered)
        text.layoutManager?.ensureLayout(for: text.textContainer!)
        let size = text.layoutManager?.usedRect(for: text.textContainer!).size ?? .zero
        text.setFrameSize(NSSize(width: max(scroll.contentSize.width, size.width + 24),
                                 height: max(scroll.contentSize.height, size.height + 24)))
        // The initial position is explicitly bottom-left; following preserves
        // a user's horizontal position instead of centering long log lines.
        let target = NSPoint(x: first ? 0 : origin.x,
                             y: first || follow ? max(0, text.frame.height - scroll.contentSize.height) : origin.y)
        scroll.contentView.scroll(to: target)
        scroll.reflectScrolledClipView(scroll.contentView)
    }
}

@MainActor
enum ContainerLogColors {
    static func render(_ raw: String) -> NSAttributedString {
        let palette = TerminalTheme.named(SettingsStore.shared.values.themeName).ansi
        func color(_ index: Int) -> NSColor { NSColor(Color(hex: palette[index])) }
        let base: [NSAttributedString.Key: Any] = [
            .font: NSFont.monospacedSystemFont(ofSize: 11.5, weight: .regular),
            .foregroundColor: NSColor(Theme.textSecondary)
        ]
        let output = NSMutableAttributedString(string: "")
        let escape = try! NSRegularExpression(pattern: "\u{001B}\\[[0-?]*[ -/]*[@-~]")
        let source = raw as NSString
        var cursor = 0
        var foreground: NSColor?
        var bold = false
        var spans: [(NSRange, NSColor?, Bool)] = []
        func append(_ range: NSRange) {
            guard range.length > 0 else { return }
            let start = output.length
            output.append(NSAttributedString(string: source.substring(with: range), attributes: base))
            spans.append((NSRange(location: start, length: range.length), foreground, bold))
        }
        for match in escape.matches(in: raw, range: NSRange(location: 0, length: source.length)) {
            append(NSRange(location: cursor, length: match.range.location - cursor))
            let sequence = source.substring(with: match.range)
            if sequence.hasSuffix("m") {
                let codes = sequence.dropFirst(2).dropLast().split(separator: ";", omittingEmptySubsequences: false).map { Int($0) ?? 0 }
                var i = 0
                while i < codes.count {
                    let code = codes[i]
                    switch code {
                    case 0: foreground = nil; bold = false
                    case 1: bold = true
                    case 22: bold = false
                    case 39: foreground = nil
                    case 30...37: foreground = color(code - 30)
                    case 90...97: foreground = color(code - 90 + 8)
                    case 38, 48:
                        if i + 4 < codes.count, codes[i + 1] == 2 {
                            if code == 38 {
                                foreground = NSColor(srgbRed: CGFloat(min(255, max(0, codes[i + 2]))) / 255,
                                                     green: CGFloat(min(255, max(0, codes[i + 3]))) / 255,
                                                     blue: CGFloat(min(255, max(0, codes[i + 4]))) / 255, alpha: 1)
                            }
                            i += 4
                        } else if i + 2 < codes.count, codes[i + 1] == 5 {
                            let n = min(255, max(0, codes[i + 2]))
                            if code == 38 {
                                if n < 16 { foreground = color(n) }
                                else if n >= 232 { foreground = NSColor(white: CGFloat(8 + (n - 232) * 10) / 255, alpha: 1) }
                                else {
                                    let v = n - 16
                                    func channel(_ c: Int) -> CGFloat { CGFloat(c == 0 ? 0 : 55 + c * 40) / 255 }
                                    foreground = NSColor(srgbRed: channel(v / 36), green: channel(v / 6 % 6), blue: channel(v % 6), alpha: 1)
                                }
                            }
                            i += 2
                        }
                    default: break
                    }
                    i += 1
                }
            }
            cursor = NSMaxRange(match.range)
        }
        append(NSRange(location: cursor, length: source.length - cursor))
        let rules: [(String, NSColor)] = [
            (#"(?m)^\d{4}-\d{2}-\d{2}T\S+"#, NSColor(Theme.textTertiary)),
            (#"\"(?:[^\"\\]|\\.)*\"\s*(?=:)"#, color(6)),
            (#"\b(?:true|false|null)\b"#, color(5)),
            (#"(?i)\b(?:trace|debug)\b"#, NSColor(Theme.textTertiary)),
            (#"(?i)\b(?:info|notice)\b"#, color(6)),
            (#"(?i)\b(?:warn|warning)\b"#, color(3)),
            (#"(?i)\b(?:error|fatal|panic|critical)\b"#, color(1))
        ]
        for (pattern, tint) in rules {
            let regex = try! NSRegularExpression(pattern: pattern)
            for match in regex.matches(in: output.string, range: NSRange(location: 0, length: output.length)) {
                output.addAttribute(.foregroundColor, value: tint, range: match.range)
            }
        }
        for (range, tint, bold) in spans {
            if let tint { output.addAttribute(.foregroundColor, value: tint, range: range) }
            if bold { output.addAttribute(.font, value: NSFont.monospacedSystemFont(ofSize: 11.5, weight: .bold), range: range) }
        }
        return output
    }
}

/// AppKit can assign the viewport after the first SwiftUI update. Reconcile
/// the document extent then so the first visible frame still shows the tail.
private final class ContainerLogScrollView: NSScrollView {
    var follow = true
    override func layout() {
        super.layout()
        guard let text = documentView as? NSTextView,
              let container = text.textContainer, let manager = text.layoutManager else { return }
        manager.ensureLayout(for: container)
        let used = manager.usedRect(for: container).size
        let size = NSSize(width: max(contentSize.width, used.width + 24),
                          height: max(contentSize.height, used.height + 24))
        if text.frame.size != size { text.setFrameSize(size) }
        if follow {
            contentView.scroll(to: NSPoint(x: contentView.bounds.origin.x,
                                          y: max(0, size.height - contentSize.height)))
            reflectScrolledClipView(contentView)
        }
    }
}
