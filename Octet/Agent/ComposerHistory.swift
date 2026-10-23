import AppKit
import SwiftUI

/// Prompts sent from Octet's conversations, per project folder, kept across
/// launches for ↑ and ↓ in the composer.
@MainActor
final class PromptHistoryStore {
    static let shared = PromptHistoryStore()
    /// Projects remembered; the least recently used go first.
    static let projectLimit = 200

    private var histories: [String: ComposerPromptHistory]
    /// Projects, most recently used last.
    private var order: [String]
    private let url: URL

    private struct Saved: Codable {
        var histories: [String: ComposerPromptHistory]
        var order: [String]
    }

    init(url: URL = EngineSession.supportDirectory.appendingPathComponent("prompt-history.json")) {
        self.url = url
        let saved = (try? Data(contentsOf: url)).flatMap { try? JSONDecoder().decode(Saved.self, from: $0) }
        histories = saved?.histories ?? [:]
        order = saved?.order ?? []
    }

    func entries(for project: String) -> [String] { histories[Self.key(project)]?.entries ?? [] }

    func record(_ prompt: String, project: String) {
        guard ComposerPromptHistory.recallable(prompt) != nil else { return }
        let key = Self.key(project)
        histories[key, default: ComposerPromptHistory()].record(prompt)
        order.removeAll { $0 == key }
        order.append(key)
        while order.count > Self.projectLimit { histories[order.removeFirst()] = nil }
        save()
    }

    private static func key(_ project: String) -> String {
        URL(fileURLWithPath: project).standardizedFileURL.path
    }

    private func save() {
        guard let data = try? JSONEncoder().encode(Saved(histories: histories, order: order)) else { return }
        try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try? data.write(to: url, options: .atomic)
    }
}

/// The composer's caret, read from and put back into the text view that
/// has the keyboard (SwiftUI's TextEditor doesn't expose its selection on
/// macOS 14).
@MainActor
enum ComposerCaret {
    static var textView: NSTextView? { NSApp.keyWindow?.firstResponder as? NSTextView }

    static func current() -> ComposerHistoryCursor.Caret {
        guard let range = textView?.selectedRange() else { return .start }
        return ComposerHistoryCursor.Caret(location: range.location, length: range.length)
    }

    /// After SwiftUI has put new text in: the caret to its start (going
    /// back, so ↑ keeps walking) or its end (going forward).
    static func place(atStart: Bool) {
        guard let view = textView else { return }
        DispatchQueue.main.async {
            let location = atStart ? 0 : (view.string as NSString).length
            view.setSelectedRange(NSRange(location: location, length: 0))
            view.scrollRangeToVisible(NSRange(location: location, length: 0))
        }
    }
}

