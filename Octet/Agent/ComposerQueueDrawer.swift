import SwiftUI

/// The follow-ups waiting behind the running turn, docked on the composer:
/// each can be edited in the composer, moved (dragged, or ↑ and ↓ on its
/// handle), sent now, or dropped. "Send now" steers the running turn where
/// the engine can take that, and otherwise stops the turn and sends it next.
struct ComposerQueueDrawer: View {
    @ObservedObject var session: AgentSession
    @ObservedObject var bridge: ConversationBridge
    @State private var expanded = true

    var body: some View {
        let held = session.heldPrompts
        let legacy = session.queuedMessages
        if !held.isEmpty || !legacy.isEmpty {
            OctetPalettePanel {
                VStack(alignment: .leading, spacing: 0) {
                    header(count: held.count + legacy.count)
                    if expanded {
                        ScrollView {
                            VStack(alignment: .leading, spacing: 0) {
                                ForEach(Array(held.enumerated()), id: \.element.id) { index, prompt in
                                    HeldPromptRow(session: session, bridge: bridge, prompt: prompt,
                                                  position: index, count: held.count)
                                    if index < held.count - 1 || !legacy.isEmpty {
                                        Rectangle().fill(Theme.divider).frame(height: 1).padding(.leading, 34)
                                    }
                                }
                                ForEach(legacy) { item in
                                    LegacyQueuedRow(session: session, item: item)
                                }
                            }
                        }
                        .frame(maxHeight: 200)
                        .fixedSize(horizontal: false, vertical: true)
                    }
                }
            }
            .accessibilityElement(children: .contain)
            .accessibilityLabel("\(held.count + legacy.count) queued \(held.count + legacy.count == 1 ? "message" : "messages")")
        }
    }

    private func header(count: Int) -> some View {
        HStack(spacing: Theme.Space.sm) {
            OctetIcon("clock", size: 12).foregroundStyle(Theme.textTertiary)
            Text("Queued").font(Theme.Text.captionMedium).foregroundStyle(Theme.textSecondary)
            Text("\(count)").font(Theme.Text.caption.monospacedDigit()).foregroundStyle(Theme.textTertiary)
            Text(session.engineSteers
                 ? "Sent when the turn ends, or steer one in now"
                 : "Sent one per turn, when \(session.engine.displayName) finishes. \(session.engine.displayName) can't take a message mid-turn.")
                .font(Theme.Text.caption)
                .foregroundStyle(Theme.textTertiary)
                .lineLimit(1)
                .truncationMode(.tail)
            Spacer(minLength: Theme.Space.md)
            OctetIconButton(icon: expanded ? "chevron.down" : "chevron.right",
                            help: expanded ? "Collapse queued messages" : "Expand queued messages", compact: true) {
                expanded.toggle()
            }
        }
        .padding(.horizontal, Theme.Space.lg)
        .padding(.vertical, Theme.Space.xs)
    }
}

private struct HeldPromptRow: View {
    @ObservedObject var session: AgentSession
    @ObservedObject var bridge: ConversationBridge
    let prompt: AgentSession.HeldPrompt
    let position: Int
    let count: Int
    @FocusState private var handleFocused: Bool
    @State private var targeted = false

    var body: some View {
        let editing = bridge.editing == .editHeld(prompt.id)
        HStack(alignment: .top, spacing: Theme.Space.md) {
            handle
            VStack(alignment: .leading, spacing: 2) {
                Text(prompt.text.isEmpty ? "Images only" : prompt.text)
                    .font(Theme.Text.body)
                    .foregroundStyle(editing ? Theme.textTertiary : Theme.textPrimary)
                    .lineLimit(2)
                    .truncationMode(.tail)
                if !prompt.attachments.isEmpty || editing {
                    Text(editing ? "Editing in the message box"
                         : prompt.attachments.count == 1 ? "1 image" : "\(prompt.attachments.count) images")
                        .font(Theme.Text.caption)
                        .foregroundStyle(editing ? Theme.accent : Theme.textTertiary)
                }
            }
            Spacer(minLength: Theme.Space.sm)
            OctetIconButton(icon: "pencil", help: "Edit in the message box", compact: true) { bridge.edit(prompt) }
                .disabled(editing)
            OctetButton(title: session.canSteer ? "Steer" : "Send Now",
                        icon: session.canSteer ? "arrow.turn.up.right" : nil, kind: .ghost, compact: true) {
                session.sendHeldNow(prompt.id)
            }
            .disabled(editing)
            .help(!session.conversation.isRunning ? "Send this now"
                  : session.canSteer ? "Send this into the running turn now, without waiting for it to end"
                  : "\(session.engine.displayName) can't take a message mid-turn: this stops the turn and sends it next")
            OctetIconButton(icon: "xmark", help: "Remove from queue", compact: true) {
                if editing { bridge.editing = nil }
                session.dropHeld(prompt.id)
            }
        }
        .padding(.horizontal, Theme.Space.lg)
        .padding(.vertical, Theme.Space.sm)
        .background(targeted ? Theme.hover : Color.clear)
        .draggable(prompt.id.uuidString) {
            Text(prompt.text).font(Theme.Text.body).lineLimit(1).padding(Theme.Space.sm)
        }
        .dropDestination(for: String.self) { ids, _ in
            guard let id = ids.first.flatMap(UUID.init(uuidString:)) else { return false }
            session.moveHeld(id, to: prompt.id)
            return true
        } isTargeted: { targeted = $0 }
        .contextMenu {
            Button("Edit") { bridge.edit(prompt) }
            Button(session.canSteer ? "Steer Now" : "Send Now") { session.sendHeldNow(prompt.id) }
            Divider()
            Button("Move Up") { session.moveHeld(prompt.id, by: -1) }.disabled(position == 0)
            Button("Move Down") { session.moveHeld(prompt.id, by: 1) }.disabled(position == count - 1)
            Divider()
            Button("Remove") { session.dropHeld(prompt.id) }
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Queued message \(position + 1) of \(count): \(prompt.text)")
    }

    /// Its place in line; focused, ↑ and ↓ move it.
    private var handle: some View {
        Text("\(position + 1)")
            .font(Theme.Text.mono(10.5, weight: .medium))
            .foregroundStyle(handleFocused ? Theme.onAccent : Theme.textTertiary)
            .frame(width: 18, height: 18)
            .background(RoundedRectangle(cornerRadius: Theme.Radius.xs).fill(handleFocused ? Theme.accent : Theme.hover))
            .padding(.top, 1)
            .focusable()
            .focused($handleFocused)
            .onKeyPress(.upArrow) {
                session.moveHeld(prompt.id, by: -1)
                return .handled
            }
            .onKeyPress(.downArrow) {
                session.moveHeld(prompt.id, by: 1)
                return .handled
            }
            .onKeyPress(.delete) {
                session.dropHeld(prompt.id)
                return .handled
            }
            .help("Drag to reorder, or focus and press ↑ or ↓")
            .accessibilityLabel("Reorder queued message")
            .accessibilityHint("Press up or down arrow to move it")
            .accessibilityAdjustableAction { direction in
                switch direction {
                case .increment: session.moveHeld(prompt.id, by: 1)
                case .decrement: session.moveHeld(prompt.id, by: -1)
                @unknown default: break
                }
            }
    }
}

/// A message an agent itself is holding for its next turn (sent before
/// Octet held follow-ups), which can only be taken back.
private struct LegacyQueuedRow: View {
    @ObservedObject var session: AgentSession
    let item: AgentItem

    var body: some View {
        if case .user(let text) = item.kind {
            HStack(alignment: .top, spacing: Theme.Space.md) {
                OctetIcon("clock", size: 12).foregroundStyle(Theme.textTertiary).frame(width: 18)
                Text(text).font(Theme.Text.body).foregroundStyle(Theme.textPrimary)
                    .lineLimit(2).textSelection(.enabled)
                Spacer(minLength: 0)
                if session.canCancelQueued(item) {
                    OctetIconButton(icon: "xmark", help: "Don't send this", compact: true) { session.cancelQueued(item) }
                }
            }
            .padding(.horizontal, Theme.Space.lg)
            .padding(.vertical, Theme.Space.sm)
        }
    }
}
