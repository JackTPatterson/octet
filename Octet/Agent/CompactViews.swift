import AppKit
import Combine
import SwiftUI

/// "+12 −3": lines added and removed, the same everywhere they're shown,
/// green and red, in counts that stay narrow (1.2k). Zero sides are left
/// out; `compactCounts` off shows the exact numbers.
struct DiffStatLabel: View {
    let added: Int
    let removed: Int
    var compactCounts = true

    var body: some View {
        HStack(spacing: 4) {
            if added > 0 {
                Text("+" + format(added)).foregroundStyle(Color(hex: AgentStateColor.done))
            }
            if removed > 0 {
                Text("\u{2212}" + format(removed)).foregroundStyle(Theme.danger)
            }
        }
        .font(Theme.captionFont.monospacedDigit())
        .help("\(added) line\(added == 1 ? "" : "s") added, \(removed) removed")
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("\(added) additions, \(removed) deletions")
    }

    private func format(_ value: Int) -> String { compactCounts ? CompactFormat.count(value) : String(value) }
}

/// How long something has been running, counting up each second, for as
/// long as it's on screen.
struct ElapsedLabel: View {
    let since: Date

    var body: some View {
        TimelineView(.periodic(from: since, by: 1)) { context in
            Text(CompactFormat.elapsed(context.date.timeIntervalSince(since)))
                .monospacedDigit()
        }
    }
}

/// A copy button that turns into a check once it's copied, for a message.
struct CopyMessageButton: View {
    let text: String
    @State private var copied = false

    var body: some View {
        Button {
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(text, forType: .string)
            ClipboardWatcher.shared.acknowledge()
            withAnimation(.easeOut(duration: 0.15)) { copied = true }
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.4) {
                withAnimation(.easeOut(duration: 0.2)) { copied = false }
            }
        } label: {
            OctetIcon(copied ? "checkmark" : "doc.on.doc", size: 11)
                .foregroundStyle(copied ? Theme.accent : Theme.textTertiary)
                .frame(width: 22, height: 20)
                .background(RoundedRectangle(cornerRadius: 5).fill(Theme.chrome))
                .overlay(RoundedRectangle(cornerRadius: 5).strokeBorder(Theme.border, lineWidth: 1))
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help(copied ? "Copied" : "Copy as Markdown")
        .accessibilityLabel(copied ? "Copied" : "Copy message")
    }
}

/// The prompt stash, shared by every conversation and kept across launches.
@MainActor
final class PromptStashStore: ObservableObject {
    static let shared = PromptStashStore()
    private static let key = "octet.promptStash"

    @Published private(set) var contents: PromptStash {
        didSet { save() }
    }

    private init() {
        let entries = UserDefaults.standard.data(forKey: Self.key)
            .flatMap { try? JSONDecoder().decode([PromptStash.Entry].self, from: $0) } ?? []
        contents = PromptStash(entries: entries)
    }

    var entries: [PromptStash.Entry] { contents.entries }

    func stash(_ text: String) -> Bool { contents.stash(text) != nil }
    func take(_ id: UUID, replacing current: String) -> String? { contents.take(id, replacing: current)?.text }
    func remove(_ id: UUID) { contents.remove(id) }
    func clear() { contents.clear() }

    private func save() {
        if let data = try? JSONEncoder().encode(contents.entries) { UserDefaults.standard.set(data, forKey: Self.key) }
    }
}

/// The composer's stash control: a bookmark that puts the draft aside, and
/// once something is there, a count that opens the stash to bring a prompt
/// back. Bringing one back while typing swaps the two.
struct PromptStashButton: View {
    @Binding var text: String
    @ObservedObject private var store = PromptStashStore.shared
    @State private var open = false
    @State private var pulse = false

    var body: some View {
        let hasDraft = !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        HStack(spacing: 2) {
            if hasDraft {
                OctetButton(title: "", icon: "pin", kind: .ghost, compact: true) { stashDraft() }
                    .help("Put this prompt aside for later (⌥⌘S)")
                    .accessibilityLabel("Stash prompt")
                    .keyboardShortcut("s", modifiers: [.command, .option])
            }
            if !store.entries.isEmpty {
                Button { open.toggle() } label: {
                    HStack(spacing: 4) {
                        OctetIcon("pin", size: 11)
                        Text("\(store.entries.count)").monospacedDigit()
                    }
                    .font(Theme.captionFont)
                    .foregroundStyle(pulse || open ? Theme.accent : Theme.textSecondary)
                    .padding(.horizontal, 7).frame(height: 22)
                    .background(Capsule().fill(open ? Theme.cardSelected : Theme.card))
                    .contentShape(Capsule())
                }
                .buttonStyle(.plain)
                .help("Stashed prompts")
                .accessibilityLabel("Stashed prompts: \(store.entries.count). Open stash.")
                .popover(isPresented: $open, arrowEdge: .top) { list }
            }
        }
    }

    private func stashDraft() {
        guard store.stash(text) else { return }
        text = ""
        withAnimation(.easeOut(duration: 0.18)) { pulse = true }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.9) { withAnimation { pulse = false } }
    }

    private var list: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Text("Stash").font(Theme.captionFont.weight(.semibold)).foregroundStyle(Theme.textTertiary)
                Spacer()
                Button("Clear") { store.clear(); open = false }
                    .buttonStyle(.plain).font(Theme.captionFont).foregroundStyle(Theme.textTertiary)
            }
            .padding(.horizontal, 12).padding(.top, 10).padding(.bottom, 6)
            ScrollView {
                VStack(alignment: .leading, spacing: 2) {
                    ForEach(store.entries) { entry in
                        StashRow(entry: entry) {
                            if let restored = store.take(entry.id, replacing: text) { text = restored }
                            open = false
                        } remove: { store.remove(entry.id) }
                    }
                }
                .padding(.horizontal, 6).padding(.bottom, 8)
            }
            .frame(maxHeight: 300)
        }
        .frame(width: 340)
        .background(Theme.chrome)
    }
}

private struct StashRow: View {
    let entry: PromptStash.Entry
    let restore: () -> Void
    let remove: () -> Void
    @State private var hovered = false

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            VStack(alignment: .leading, spacing: 2) {
                Text(entry.title).font(Theme.uiFont).foregroundStyle(Theme.textPrimary).lineLimit(1)
                Text(entry.createdAt, style: .relative).font(Theme.captionFont).foregroundStyle(Theme.textTertiary)
            }
            Spacer(minLength: 4)
            if hovered {
                Button(action: remove) {
                    Image(systemName: "xmark").font(.system(size: 9, weight: .bold)).foregroundStyle(Theme.textTertiary)
                }
                .buttonStyle(.plain)
                .help("Remove from the stash")
                .accessibilityLabel("Remove")
            }
        }
        .padding(.horizontal, 8).padding(.vertical, 6)
        .background(RoundedRectangle(cornerRadius: 6).fill(hovered ? Theme.hover : .clear))
        .contentShape(Rectangle())
        .onTapGesture(perform: restore)
        .onHover { hovered = $0 }
        .help(entry.text)
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(.isButton)
        .accessibilityHint("Puts it back in the message box")
    }
}
