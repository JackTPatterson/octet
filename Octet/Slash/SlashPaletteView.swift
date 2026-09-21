import SwiftUI

/// The `/` menu, styled like Octet's command palette and anchored over the
/// terminal so it reads as part of the prompt.
struct SlashPaletteView: View {
    @ObservedObject var slash: SlashController
    @FocusState private var focused: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 6) {
                Text(slash.breadcrumb)
                    .font(Theme.monoFont)
                    .foregroundStyle(Theme.accent)
                    .lineLimit(1)
                TextField("", text: $slash.query)
                    .textFieldStyle(.plain)
                    .font(Theme.monoFont)
                    .foregroundStyle(Theme.textPrimary)
                    .focused($focused)
                    .onSubmit { slash.choose() }
                Text(slash.agentName)
                    .font(Theme.captionFont)
                    .foregroundStyle(Theme.textTertiary)
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 9)

            Rectangle().fill(Theme.divider).frame(height: 1)

            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(spacing: 1) {
                        ForEach(Array(slash.matches.enumerated()), id: \.element.id) { index, command in
                            CommandRow(command: command, selected: index == slash.selection)
                                .id(command.id)
                                .onTapGesture { slash.choose(command) }
                        }
                    }
                    .padding(6)
                }
                .frame(maxHeight: 280)
                .onChange(of: slash.selection) { _, index in
                    guard slash.matches.indices.contains(index) else { return }
                    proxy.scrollTo(slash.matches[index].id)
                }
            }

            Rectangle().fill(Theme.divider).frame(height: 1)
            HStack(spacing: 10) {
                Hint(keys: "↩", label: slash.selectedHasChildren ? "Open" : (slash.selectedRuns ? "Run" : "Type"))
                Hint(keys: "⌘↩", label: "Type only")
                if slash.path.isEmpty {
                    Hint(keys: "esc", label: "Keep typing")
                } else {
                    Hint(keys: "←", label: "Back")
                }
                Spacer()
                Text("\(slash.matches.count)")
                    .font(Theme.captionFont)
                    .foregroundStyle(Theme.textTertiary)
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 7)
        }
        .frame(width: 460)
        .background(Theme.card)
        .clipShape(RoundedRectangle(cornerRadius: 8))
        .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(Theme.border, lineWidth: 1))
        .shadow(color: .black.opacity(0.4), radius: 22, y: 10)
        .onAppear { DispatchQueue.main.async { focused = true } }
        .onExitCommand { slash.cancel() }
        // Clicking the terminal, opening the palette, or switching windows
        // takes focus away: close rather than keep eating arrow keys.
        .onChange(of: focused) { _, isFocused in
            if !isFocused && slash.isOpen { slash.close() }
        }
        .background {
            // Arrow keys and ⌘↩ while the field holds focus.
            KeyCatcher(
                isActive: { slash.isOpen },
                up: { slash.moveSelection(-1) },
                down: { slash.moveSelection(1) },
                submitRunning: { slash.choose(insert: true) },
                right: {
                    guard slash.selectedHasChildren else { return false }
                    slash.openSelected()
                    return true
                },
                back: {
                    guard slash.query.isEmpty else { return false }
                    slash.ascend()
                    return true
                },
                backspace: {
                    guard slash.query.isEmpty else { return false }
                    slash.backspaceOnEmpty()
                    return true
                }
            )
        }
    }
}

private struct CommandRow: View {
    let command: SlashCommand
    let selected: Bool

    var body: some View {
        HStack(spacing: 8) {
            // Arguments read as values, not commands: no leading slash.
            Text(command.origin == .argument ? command.name : "/" + command.name)
                .font(Theme.monoFont)
                .foregroundStyle(selected ? Theme.textPrimary : Theme.textSecondary)
                .lineLimit(1)
            if !command.summary.isEmpty {
                Text(command.summary)
                    .font(Theme.captionFont)
                    .foregroundStyle(Theme.textTertiary)
                    .lineLimit(1)
            }
            if !command.argumentHint.isEmpty {
                Text(command.argumentHint)
                    .font(Theme.captionFont)
                    .foregroundStyle(Theme.textTertiary.opacity(0.8))
            }
            Spacer(minLength: 4)
            if command.hasChildren {
                Text("\(command.children.count)")
                    .font(Theme.captionFont)
                    .foregroundStyle(Theme.textTertiary)
                OctetIcon("chevron.right", size: 11)
                    .foregroundStyle(Theme.textTertiary)
            }
            if !command.origin.label.isEmpty {
                Text(command.origin.label)
                    .font(Theme.captionFont)
                    .foregroundStyle(Theme.textTertiary)
                    .padding(.horizontal, 5)
                    .padding(.vertical, 1)
                    .background(RoundedRectangle(cornerRadius: 3).fill(Theme.hover))
            }
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 5)
        .background(selected ? Theme.cardSelected : Color.clear)
        .clipShape(RoundedRectangle(cornerRadius: Theme.rowRadius))
        .contentShape(Rectangle())
    }
}

private struct Hint: View {
    let keys: String
    let label: String

    var body: some View {
        HStack(spacing: 4) {
            Text(keys)
                .font(Theme.captionFont)
                .foregroundStyle(Theme.textSecondary)
                .padding(.horizontal, 4)
                .padding(.vertical, 1)
                .background(RoundedRectangle(cornerRadius: 3).fill(Theme.hover))
            Text(label)
                .font(Theme.captionFont)
                .foregroundStyle(Theme.textTertiary)
        }
    }
}

/// Arrow-key and ⌘↩ handling that a plain TextField swallows.
private struct KeyCatcher: NSViewRepresentable {
    /// The monitor is app-wide, so every key it takes is gated on the menu
    /// still being open.
    let isActive: () -> Bool
    let up: () -> Void
    let down: () -> Void
    let submitRunning: () -> Void
    /// → opens the highlighted submenu and ← goes back; each returns false
    /// when it doesn't apply, so the key moves the caret instead.
    let right: () -> Bool
    let back: () -> Bool
    /// ⌫ on an empty query; false lets the field delete a character.
    let backspace: () -> Bool

    func makeNSView(context: Context) -> NSView {
        let view = NSView()
        context.coordinator.host = view
        context.coordinator.install(isActive: isActive, up: up, down: down, submitRunning: submitRunning,
                                    right: right, back: back, backspace: backspace)
        return view
    }

    func updateNSView(_ nsView: NSView, context: Context) {
        context.coordinator.install(isActive: isActive, up: up, down: down, submitRunning: submitRunning,
                                    right: right, back: back, backspace: backspace)
    }

    func makeCoordinator() -> Coordinator { Coordinator() }

    final class Coordinator {
        private var monitor: Any?
        private var isActive: (() -> Bool)?
        private var up: (() -> Void)?
        private var down: (() -> Void)?
        private var submitRunning: (() -> Void)?
        private var right: (() -> Bool)?
        private var back: (() -> Bool)?
        private var backspace: (() -> Bool)?
        /// Only keys aimed at the menu's own window count.
        weak var host: NSView?

        func install(
            isActive: @escaping () -> Bool,
            up: @escaping () -> Void,
            down: @escaping () -> Void,
            submitRunning: @escaping () -> Void,
            right: @escaping () -> Bool,
            back: @escaping () -> Bool,
            backspace: @escaping () -> Bool
        ) {
            self.isActive = isActive
            self.up = up
            self.down = down
            self.submitRunning = submitRunning
            self.right = right
            self.back = back
            self.backspace = backspace
            guard monitor == nil else { return }
            monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
                guard let self, self.isActive?() == true,
                      let window = self.host?.window, event.window === window else { return event }
                switch event.keyCode {
                case 126: self.up?(); return nil
                case 125: self.down?(); return nil
                case 36, 76 where event.modifierFlags.contains(.command):
                    if event.modifierFlags.contains(.command) {
                        self.submitRunning?()
                        return nil
                    }
                    return event
                case 124: return self.right?() == true ? nil : event
                case 123: return self.back?() == true ? nil : event
                case 51: return self.backspace?() == true ? nil : event
                case 48: // Tab completes like ↩ without running.
                    return event
                default: return event
                }
            }
        }

        deinit {
            if let monitor { NSEvent.removeMonitor(monitor) }
        }
    }
}
