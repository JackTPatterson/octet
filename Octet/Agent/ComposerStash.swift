import AppKit
import Combine
import SwiftUI

/// The prompt stash, kept per project across launches in Octet's support
/// folder (images make it too big for preferences).
@MainActor
final class PromptStashStore: ObservableObject {
    static let shared = PromptStashStore()
    /// Where the stash lived when it was text only and shared by everything.
    static let legacyKey = "octet.promptStash"

    @Published private(set) var contents: PromptStash {
        didSet { if contents != oldValue { save() } }
    }
    /// Bumped on every stash, so the badge can catch the eye.
    @Published private(set) var lastStashed: Date?

    private let url: URL

    init(url: URL = EngineSession.supportDirectory.appendingPathComponent("prompt-stash.json"),
         defaults: UserDefaults = .standard) {
        self.url = url
        var entries = (try? Data(contentsOf: url)).flatMap { try? JSONDecoder().decode([PromptStash.Entry].self, from: $0) } ?? []
        // The older shared stash joins in, shown in every project until used.
        let legacy = defaults.data(forKey: Self.legacyKey)
        if let legacy {
            entries += (try? JSONDecoder().decode([PromptStash.Entry].self, from: legacy)) ?? []
        }
        contents = PromptStash(entries: entries)
        if legacy != nil {
            save()
            defaults.removeObject(forKey: Self.legacyKey)
        }
    }

    func entries(in project: String) -> [PromptStash.Entry] { contents.entries(in: project) }

    @discardableResult
    func stash(_ text: String, images: [Data], project: String) -> Bool {
        guard contents.stash(text, images: images, project: project) != nil else { return false }
        lastStashed = Date()
        return true
    }

    func take(_ id: UUID, replacing text: String, images: [Data], project: String) -> PromptStash.Entry? {
        contents.take(id, replacing: text, images: images, project: project)
    }

    func remove(_ id: UUID) { contents.remove(id) }
    func clear(project: String) { contents.clear(project: project) }

    private func save() {
        guard let data = try? JSONEncoder().encode(contents.entries) else { return }
        try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try? data.write(to: url, options: .atomic)
    }

    #if DEBUG
    /// Verification hook: a few drafts in `project`'s stash.
    func debugSeed(project: String) {
        guard entries(in: project).isEmpty else { return }
        let image = NSImage(size: NSSize(width: 32, height: 32), flipped: false) { rect in
            NSColor.systemTeal.setFill()
            NSBezierPath(roundedRect: rect, xRadius: 6, yRadius: 6).fill()
            return true
        }
        let attachment = AgentSession.Attachment(image: image)?.data
        let now = Date()
        contents.stash("Add retry with backoff to the upload client, and cover the give-up path with a test",
                       project: project, at: now.addingTimeInterval(-3_600 * 5))
        contents.stash("", images: attachment.map { [$0] } ?? [], project: project, at: now.addingTimeInterval(-600))
        contents.stash("Why does the sidebar flicker when a workspace is renamed?\nIt only happens with two windows open.",
                       images: attachment.map { [$0, $0] } ?? [], project: project, at: now.addingTimeInterval(-45))
    }
    #endif
}

extension AgentSession.Attachment {
    /// An image the composer already encoded, coming back from the stash.
    init(encoded data: Data) {
        self.data = data
        mediaType = data.starts(with: [0x89, 0x50, 0x4E, 0x47]) ? "image/png" : "image/jpeg"
    }
}

/// Stashing from the composer, by its button or ⌘S. ⌘S is the editor's Save
/// in the menu bar; while a conversation's message box has focus the menu
/// hands it here instead.
@MainActor
enum ComposerStash {
    private static var focused: (owner: String, stash: () -> Void)?

    /// The focused composer takes ⌘S.
    static func focus(_ owner: String, stash: @escaping () -> Void) { focused = (owner, stash) }

    static func blur(_ owner: String) {
        if focused?.owner == owner { focused = nil }
    }

    /// Stashes the focused composer's draft. False when no message box has
    /// the keyboard, so ⌘S saves as usual.
    static func stashFocused() -> Bool {
        guard let focused, NSApp.keyWindow?.firstResponder is NSTextView else { return false }
        focused.stash()
        return true
    }

    /// Puts the draft aside and empties the composer. Nothing happens to an
    /// empty composer.
    @discardableResult
    static func stash(text: Binding<String>, attachments: Binding<[AgentSession.Attachment]>, project: String) -> Bool {
        guard PromptStashStore.shared.stash(text.wrappedValue, images: attachments.wrappedValue.map(\.data), project: project) else {
            NSSound.beep()
            return false
        }
        text.wrappedValue = ""
        attachments.wrappedValue = []
        AccessibilityNotification.Announcement("Prompt stashed").post()
        return true
    }

    /// Brings an entry back; what the composer held takes its place.
    static func restore(_ entry: PromptStash.Entry, text: Binding<String>,
                        attachments: Binding<[AgentSession.Attachment]>, project: String) {
        guard let taken = PromptStashStore.shared.take(entry.id, replacing: text.wrappedValue,
                                                       images: attachments.wrappedValue.map(\.data), project: project) else { return }
        text.wrappedValue = taken.text
        attachments.wrappedValue = taken.images.map(AgentSession.Attachment.init(encoded:))
    }
}

/// The composer's stash controls: a pin that puts the draft aside, and once
/// something is stashed, a count that opens the stash menu above the
/// composer, as T3 Code's stash badge does.
struct ComposerStashControls: View {
    let project: String
    @Binding var text: String
    @Binding var attachments: [AgentSession.Attachment]
    @ObservedObject var dropdowns: OctetDropdownState
    @ObservedObject private var store = PromptStashStore.shared
    @State private var pulse = false

    static let menuId = "stash"

    var body: some View {
        let entries = store.entries(in: project)
        let hasDraft = !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || !attachments.isEmpty
        HStack(spacing: 2) {
            if hasDraft {
                OctetButton(title: "", icon: "pin", kind: .ghost, compact: true) {
                    ComposerStash.stash(text: $text, attachments: $attachments, project: project)
                }
                .help("Stash this prompt for later (⌘S)")
                .accessibilityLabel("Stash prompt")
            }
            if !entries.isEmpty {
                OctetDropdownAnchor(spec: spec, state: dropdowns) { open in
                    HStack(spacing: 4) {
                        OctetIcon("pin", size: 11)
                        Text("Stash")
                        Text("\(entries.count)").monospacedDigit()
                            .foregroundStyle(pulse ? Theme.accent : open ? Theme.textPrimary : Theme.textTertiary)
                    }
                    .font(Theme.captionFont)
                    .foregroundStyle(pulse || open ? Theme.textPrimary : Theme.textSecondary)
                    .padding(.horizontal, 8).frame(height: 22)
                    .background(Capsule().fill(open ? Theme.cardSelected : Theme.card))
                    .overlay(Capsule().strokeBorder(open ? Theme.accent.opacity(0.6) : Theme.border, lineWidth: 1))
                }
                .help("Stashed prompts in this project")
                .accessibilityLabel("Stashed prompts: \(entries.count). Open stash.")
                .transition(.opacity.combined(with: .scale(scale: 0.9)))
            }
        }
        .animation(.easeOut(duration: 0.18), value: entries.count)
        .onChange(of: store.lastStashed) { _, _ in
            withAnimation(.easeOut(duration: 0.18)) { pulse = true }
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.9) { withAnimation { pulse = false } }
        }
    }

    private var spec: OctetDropdownSpec {
        OctetDropdownSpec(id: Self.menuId, options: [], selected: "", select: { _ in }, panel: { close in
            AnyView(ComposerStashMenu(project: project, restore: { entry in
                ComposerStash.restore(entry, text: $text, attachments: $attachments, project: project)
                close()
            }, close: close))
        })
    }
}

/// The stash, as a panel over the composer: each draft's first words, its
/// images, when it was put aside, and a cross to drop it. ↑↓ move, Return
/// brings one back, ⌘⌫ deletes, Esc closes.
struct ComposerStashMenu: View {
    let project: String
    let restore: (PromptStash.Entry) -> Void
    let close: () -> Void
    @ObservedObject private var store = PromptStashStore.shared
    @State private var highlighted = 0
    @FocusState private var focused: Bool

    var body: some View {
        let entries = store.entries(in: project)
        OctetPalettePanel(style: .floating, divider: .none) {
            VStack(alignment: .leading, spacing: 0) {
                HStack(spacing: 6) {
                    OctetIcon("pin", size: 11).foregroundStyle(Theme.textTertiary)
                    Text("STASH").font(Theme.headerFont).kerning(0.4).foregroundStyle(Theme.textTertiary)
                    Text("\(entries.count)").font(Theme.captionFont.monospacedDigit()).foregroundStyle(Theme.textTertiary)
                    Spacer(minLength: 12)
                    if !entries.isEmpty {
                        OctetButton(title: "Clear", kind: .ghost, compact: true) {
                            store.clear(project: project)
                            close()
                        }
                        .help("Delete every stashed prompt in this project")
                    }
                }
                .padding(.leading, 10).padding(.trailing, 4).padding(.vertical, 4)
                Rectangle().fill(Theme.divider).frame(height: 1)
                if entries.isEmpty {
                    Text("Nothing stashed. Press ⌘S with a prompt in the message box to stash it.")
                        .font(Theme.uiFont).foregroundStyle(Theme.textTertiary)
                        .padding(12)
                } else {
                    ScrollView {
                        OctetAnimatedList(items: entries, highlighted: min(highlighted, entries.count - 1),
                                          highlight: { highlighted = $0 }, choose: restore) { entry, selected in
                            StashMenuRow(entry: entry, selected: selected) { store.remove(entry.id) }
                        }
                        .padding(4)
                    }
                    .frame(maxHeight: 280)
                    .fixedSize(horizontal: false, vertical: true)
                }
                HStack(spacing: 10) {
                    hint("↩", "restore")
                    hint("⌘⌫", "delete")
                    hint("esc", "close")
                }
                .padding(.horizontal, 10).padding(.vertical, 5)
                .frame(maxWidth: .infinity, alignment: .leading)
                .overlay(alignment: .top) { Rectangle().fill(Theme.divider).frame(height: 1) }
            }
        }
        .frame(width: 420)
        .focusable()
        .focusEffectDisabled()
        .focused($focused)
        .onAppear { DispatchQueue.main.async { focused = true } }
        .onKeyPress(.upArrow) { move(-1, in: entries); return .handled }
        .onKeyPress(.downArrow) { move(1, in: entries); return .handled }
        .onKeyPress(.return) {
            if entries.indices.contains(highlighted) { restore(entries[highlighted]) }
            return .handled
        }
        .onKeyPress(.delete, phases: .down) { press in
            guard press.modifiers.contains(.command), entries.indices.contains(highlighted) else { return .ignored }
            store.remove(entries[highlighted].id)
            highlighted = max(0, min(highlighted, entries.count - 2))
            return .handled
        }
        .onExitCommand(perform: close)
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Stashed prompts")
    }

    private func move(_ delta: Int, in entries: [PromptStash.Entry]) {
        guard !entries.isEmpty else { return }
        highlighted = (min(highlighted, entries.count - 1) + delta + entries.count) % entries.count
    }

    private func hint(_ key: String, _ label: String) -> some View {
        HStack(spacing: 4) {
            Text(key).font(Theme.captionFont.weight(.medium)).foregroundStyle(Theme.textSecondary)
            Text(label).font(Theme.captionFont).foregroundStyle(Theme.textTertiary)
        }
    }
}

private struct StashMenuRow: View {
    let entry: PromptStash.Entry
    let selected: Bool
    let remove: () -> Void

    var body: some View {
        HStack(spacing: 8) {
            OctetIcon("doc", size: 11).foregroundStyle(Theme.textTertiary)
            Text(entry.snippet)
                .font(Theme.uiFont)
                .foregroundStyle(entry.text.isEmpty ? Theme.textSecondary : Theme.textPrimary)
                .lineLimit(1)
                .truncationMode(.tail)
            Spacer(minLength: 6)
            if !entry.images.isEmpty {
                HStack(spacing: -5) {
                    ForEach(Array(entry.images.prefix(3).enumerated()), id: \.offset) { _, data in
                        if let image = NSImage(data: data) {
                            Image(nsImage: image).resizable().aspectRatio(contentMode: .fill)
                                .frame(width: 16, height: 16)
                                .clipShape(RoundedRectangle(cornerRadius: 3))
                                .overlay(RoundedRectangle(cornerRadius: 3).strokeBorder(Theme.border, lineWidth: 1))
                        }
                    }
                }
                .accessibilityLabel("\(entry.images.count) image\(entry.images.count == 1 ? "" : "s")")
            }
            Text(Self.age(entry.createdAt))
                .font(Theme.captionFont.monospacedDigit())
                .foregroundStyle(Theme.textTertiary)
            Button(action: remove) {
                OctetIcon("xmark", size: 10)
                    .foregroundStyle(Theme.textTertiary)
                    .frame(width: 18, height: 18)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .opacity(selected ? 1 : 0.35)
            .help("Delete this stashed prompt (⌘⌫)")
            .accessibilityLabel("Delete stashed prompt")
        }
        .frame(minHeight: 22)
        .help(entry.text)
        .accessibilityHint("Puts it back in the message box")
    }

    /// "now", "4m", "5h", "3d": T3 Code's short relative times.
    static func age(_ date: Date, now: Date = Date()) -> String {
        let seconds = Int(now.timeIntervalSince(date))
        if seconds < 60 { return "now" }
        if seconds < 3_600 { return "\(seconds / 60)m" }
        if seconds < 86_400 { return "\(seconds / 3_600)h" }
        return "\(seconds / 86_400)d"
    }
}
