import SwiftUI

/// Notes held to go out with the next prompt the person sends in a project,
/// rather than as a message of their own. The composer asks for them as it
/// sends (`attach(to:cwd:)`), so they reach whichever agent is spoken to
/// next, in the same message.
@MainActor
final class ReviewNotesOutbox: ObservableObject {
    static let shared = ReviewNotesOutbox()

    /// By project root.
    @Published private(set) var riding: [String: [ReviewComment]] = [:]

    private static func root(_ directory: String) -> String {
        AccountProfiles.projectRoot(of: directory) ?? directory
    }

    func notes(for directory: String) -> [ReviewComment] { riding[Self.root(directory)] ?? [] }

    /// Holds `notes` for the next prompt in `directory`'s project, after any
    /// already held.
    func hold(_ notes: [ReviewComment], for directory: String) {
        guard !notes.isEmpty else { return }
        riding[Self.root(directory), default: []] += notes
    }

    func drop(for directory: String) { riding[Self.root(directory)] = nil }

    /// The message with any held notes for `cwd`'s project after it, and
    /// those notes let go: they ride along once.
    func attach(to message: String, cwd: String) -> String {
        let key = Self.root(cwd)
        guard let notes = riding[key], !notes.isEmpty else { return message }
        riding[key] = nil
        return ReviewComment.attaching(notes, to: message)
    }
}

/// Where notes can go: an agent already working in the project, in a
/// terminal or an Octet conversation, or a new conversation there.
enum ReviewNoteTarget: Hashable {
    case pane(String)
    case conversation(String)
    case newConversation

    struct Option: Identifiable {
        let target: ReviewNoteTarget
        let name: String
        var id: ReviewNoteTarget { target }
    }

    /// Agents in `directory`'s project, the one in front first, then its
    /// conversations, then a new conversation.
    @MainActor
    static func options(in store: SessionStore, directory: String) -> [Option] {
        let top = AccountProfiles.projectRoot(of: directory) ?? directory
        let panes = DiffReviewView.agents(in: store, directory: directory)
            .map { Option(target: .pane($0.paneId), name: DiffReviewView.name($0, in: store)) }
        let conversations = AgentCenter.shared.sessions
            .filter { AccountProfiles.contains(top, $0.cwd) || AccountProfiles.projectRoot(of: $0.cwd) == top }
            .map { Option(target: .conversation($0.id), name: "\($0.engine.displayName): \($0.title)") }
        return panes + conversations + [Option(target: .newConversation, name: "New conversation")]
    }

    /// Sends `prompt` there; a new conversation opens in the window's
    /// workspace, in `directory`.
    @MainActor
    func send(_ prompt: String, store: SessionStore, window: WindowContext, directory: String, name: String) {
        switch self {
        case .pane(let paneId):
            store.broadcast(prompt, to: [Broadcast.Target(paneId: paneId, name: name, isAgent: true)])
        case .conversation(let id):
            guard let session = AgentCenter.shared.sessions.first(where: { $0.id == id }) else {
                ToastCenter.shared.info("That conversation has closed", detail: "Pick another agent and send again.")
                return
            }
            session.send(prompt)
            AgentCenter.shared.setActive(session.id, in: session.workspaceId)
        case .newConversation:
            guard let workspace = window.focusedWorkspace else {
                ToastCenter.shared.info("No workspace to open it in", detail: "Open a tab in this project, then send again.")
                return
            }
            let session = AgentCenter.shared.newConversation(workspaceId: workspace.workspaceId, cwd: directory)
            session.send(prompt)
        }
    }
}

/// The notes written so far, listed, with where each is and whether the
/// code it's about has since changed, and Send to Agent (⌘↩) for the
/// agent picked, or "With my next prompt" to send them along with what the
/// person writes next. The Diff plane and the review share it.
struct ReviewNotesTray: View {
    @EnvironmentObject private var window: WindowContext
    @ObservedObject var model: DiffReviewModel
    @ObservedObject var store: SessionStore
    @ObservedObject private var outbox = ReviewNotesOutbox.shared
    /// Narrow (the Diff plane): the list stacks over the buttons.
    var compact = false
    /// Brings a note's line into view.
    var jump: (ReviewComment) -> Void = { _ in }
    @State private var open = true
    @State private var picked: ReviewNoteTarget?

    var body: some View {
        let options = ReviewNoteTarget.options(in: store, directory: model.directory)
        let target = options.first { $0.target == picked } ?? options.first
        let count = model.comments.count
        let held = outbox.notes(for: model.directory).count
        VStack(alignment: .leading, spacing: 0) {
            if open && count > 0 {
                ScrollView {
                    VStack(alignment: .leading, spacing: 2) {
                        ForEach(model.comments) { note in row(note) }
                    }
                    .padding(.horizontal, 8)
                    .padding(.vertical, 6)
                }
                .frame(maxHeight: 160)
                .fixedSize(horizontal: false, vertical: true)
                Rectangle().fill(Theme.divider).frame(height: 1)
            }
            HStack(spacing: 8) {
                if count > 0 {
                    Button { MotionPreferences.shared.perform(.sidebar) { open.toggle() } } label: {
                        HStack(spacing: 4) {
                            OctetIcon("chevron.right", size: 9)
                                .rotationEffect(.degrees(open ? 90 : 0))
                            Text("\(count) \(count == 1 ? "note" : "notes")")
                        }
                        .font(Theme.captionFont)
                        .foregroundStyle(Theme.textSecondary)
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel(open ? "Hide notes" : "Show notes")
                    OctetButton(title: "Clear", kind: .ghost, compact: true) { model.comments = [] }
                } else if held > 0 {
                    Text("\(held) \(held == 1 ? "note goes" : "notes go") with your next prompt")
                        .font(Theme.captionFont).foregroundStyle(Theme.textSecondary).lineLimit(1)
                    OctetButton(title: "Take Back", kind: .ghost, compact: true) {
                        model.comments += outbox.notes(for: model.directory)
                        outbox.drop(for: model.directory)
                    }
                    .help("Keep them here instead")
                } else {
                    Text("Click a line to leave a note for the agent; shift-click to cover several.")
                        .font(Theme.captionFont).foregroundStyle(Theme.textTertiary).lineLimit(1)
                }
                Spacer(minLength: 4)
                if count > 0 {
                    if options.count > 1 && !compact {
                        OctetSelect(selection: Binding(get: { target?.target ?? .newConversation }, set: { picked = $0 }),
                                    options: options.map { ($0.target, $0.name) }, width: 200)
                            .accessibilityLabel("Send to")
                    }
                    sendButton(target)
                }
            }
            .padding(.horizontal, 10)
            .frame(height: 40)
        }
    }

    private func sendButton(_ target: ReviewNoteTarget.Option?) -> some View {
        HStack(spacing: 2) {
            OctetButton(title: compact ? "Send" : "Send to Agent", icon: "arrow.up", kind: .primary, compact: true) {
                if let target { send(to: target) }
            }
            .keyboardShortcut(.return, modifiers: .command)
            .help("Send the notes to \(target?.name ?? "the agent") as one message (⌘↩)")
            OctetIconButton(icon: "chevron.down", help: "More ways to send the notes", compact: true) {
                presentMenu()
            }
        }
    }

    private func presentMenu() {
        let options = ReviewNoteTarget.options(in: store, directory: model.directory)
        var items: [OctetMenuItem] = [.header("Send to")]
        items += options.map { option in
            .action(option.name, icon: option.target == .newConversation ? "plus" : nil) {
                picked = option.target
                send(to: option)
            }
        }
        items += [
            .divider,
            .action("With My Next Prompt", icon: "text.bubble",
                    help: "Add them to the next message you send to an agent in this project") {
                outbox.hold(model.comments, for: model.directory)
                model.comments = []
            },
        ]
        OctetContextMenu.present(items)
    }

    private func send(to option: ReviewNoteTarget.Option) {
        let prompt = ReviewComment.prompt(model.comments)
        guard !prompt.isEmpty else { return }
        option.target.send(prompt, store: store, window: window, directory: model.directory, name: option.name)
        model.comments = []
    }

    private func row(_ note: ReviewComment) -> some View {
        let outdated = model.isOutdated(note)
        return HStack(alignment: .firstTextBaseline, spacing: 6) {
            Button { jump(note) } label: {
                HStack(alignment: .firstTextBaseline, spacing: 6) {
                    Text("\((note.path as NSString).lastPathComponent):\(note.location)")
                        .font(Theme.Text.mono(11))
                        .foregroundStyle(Theme.textSecondary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                    if outdated {
                        Text("Outdated")
                            .font(Theme.Text.micro.weight(.medium))
                            .foregroundStyle(Theme.warning)
                            .padding(.horizontal, 5)
                            .background(Capsule().fill(Theme.warning.opacity(0.15)))
                            .help("That code has changed since; the note may no longer apply")
                    }
                    Text(note.text)
                        .font(Theme.captionFont)
                        .foregroundStyle(outdated ? Theme.textTertiary : Theme.textPrimary)
                        .lineLimit(2)
                    Spacer(minLength: 0)
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .help("\(note.path):\(note.location)")
            OctetIconButton(icon: "xmark", help: "Remove this note", compact: true) {
                model.comments.removeAll { $0.id == note.id }
            }
        }
        .accessibilityElement(children: .contain)
    }
}
