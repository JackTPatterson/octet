import AppKit

/// Lets the Vim engine work on a text view: reads and writes go through the
/// view's own undo and change notifications, so edits save, highlight and
/// undo like any other.
final class TextViewVimBuffer: VimBuffer {
    weak var textView: NSTextView?

    init(textView: NSTextView) { self.textView = textView }

    var string: NSString {
        MainActor.assumeIsolated { (textView?.textStorage?.string ?? "") as NSString }
    }

    var selection: NSRange {
        get { MainActor.assumeIsolated { textView?.selectedRange() ?? NSRange(location: 0, length: 0) } }
        set {
            MainActor.assumeIsolated {
                textView?.setSelectedRange(newValue)
                textView?.scrollRangeToVisible(newValue)
            }
        }
    }

    func replace(_ range: NSRange, with text: String) {
        MainActor.assumeIsolated {
            guard let textView, textView.shouldChangeText(in: range, replacementString: text) else { return }
            textView.textStorage?.replaceCharacters(in: range, with: text)
            textView.didChangeText()
        }
    }
}

enum VimKeys {
    /// The engine's name for a key, or nil for one Vim doesn't take: anything
    /// with ⌘ or ⌥, which belong to the app and the system.
    static func name(for event: NSEvent) -> String? {
        let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
        if flags.contains(.command) || flags.contains(.option) { return nil }
        switch event.keyCode {
        case 53: return "<Esc>"
        case 36, 76: return "<CR>"
        case 51: return "<BS>"
        case 48: return "<Tab>"
        case 123: return "<Left>"
        case 124: return "<Right>"
        case 125: return "<Down>"
        case 126: return "<Up>"
        default: break
        }
        if flags.contains(.control) {
            guard let key = event.charactersIgnoringModifiers?.lowercased(), key.count == 1 else { return nil }
            return "<C-\(key)>"
        }
        guard let characters = event.characters, characters.count == 1, characters.unicodeScalars.allSatisfy({ $0.value >= 32 && $0.value != 127 }) else { return nil }
        return characters
    }
}
