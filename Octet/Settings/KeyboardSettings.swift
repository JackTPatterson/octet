import AppKit
import SwiftUI

/// Settings › Keyboard, after T3 Code's Keybindings page: every shortcut in
/// `OctetShortcut.groups`, the values the menus bind, each with a keycap
/// that records a new key when clicked.
struct KeyboardSettings: View {
    @ObservedObject var settings: SettingsStore
    @State private var query = ""
    /// The shortcut whose keycap is listening for a key, if any.
    @State private var recording: String?

    private var overrides: [String: String] { settings.values.shortcutOverrides }

    var body: some View {
        // Read here so every row redraws when a shortcut changes.
        let conflicts = OctetShortcut.table.conflicts(overrides: overrides)
        let groups = filteredGroups
        toolbar
        if groups.isEmpty {
            Text("No shortcuts match your search.")
                .font(Theme.uiFont)
                .foregroundStyle(Theme.textTertiary)
                .frame(maxWidth: .infinity)
                .padding(.vertical, 24)
        }
        ForEach(groups, id: \.title) { group in
            SettingsGroup(title: group.title) {
                ForEach(Array(group.shortcuts.enumerated()), id: \.element.id) { index, shortcut in
                    if index > 0 { SettingsDivider() }
                    ShortcutRow(
                        shortcut: shortcut,
                        isCustom: shortcut.isCustom,
                        conflict: conflicts[shortcut.id],
                        recording: Binding(
                            get: { recording == shortcut.id },
                            set: { recording = $0 ? shortcut.id : nil }
                        ),
                        save: { save($0, for: shortcut) },
                        reset: { settings.values.shortcutOverrides = OctetShortcut.table.reset(shortcut.id, overrides: overrides) }
                    )
                }
            }
        }
    }

    private var toolbar: some View {
        HStack(spacing: 10) {
            OctetTextField(placeholder: "Search shortcuts", text: $query)
                .frame(maxWidth: 320)
            Spacer(minLength: 0)
            OctetButton(title: "Reset All to Defaults") {
                ConfirmCenter.shared.ask(
                    title: "Reset all shortcuts?",
                    message: "Every shortcut goes back to its default key.",
                    confirmTitle: "Reset All",
                    destructive: true
                ) { _ in
                    settings.values.shortcutOverrides = [:]
                    ToastCenter.shared.info("Shortcuts restored to defaults")
                }
            }
            .disabled(overrides.isEmpty)
        }
    }

    /// Matches a shortcut's title, its group, or its keys ("⌘⇧" finds
    /// every ⌘⇧ shortcut; "cmd" isn't spelled out anywhere, so symbols it is).
    private var filteredGroups: [(title: String, shortcuts: [OctetShortcut])] {
        let needle = query.trimmingCharacters(in: .whitespaces).lowercased()
        guard !needle.isEmpty else { return OctetShortcut.groups }
        return OctetShortcut.groups.compactMap { group in
            if group.title.lowercased().contains(needle) { return group }
            let matches = group.shortcuts.filter {
                $0.title.lowercased().contains(needle) || $0.display.lowercased().contains(needle)
            }
            return matches.isEmpty ? nil : (group.title, matches)
        }
    }

    /// The most recent binding wins: whatever held the key before is
    /// unassigned, and a toast says which, so nothing changes unseen.
    private func save(_ binding: ShortcutBinding?, for shortcut: OctetShortcut) {
        switch OctetShortcut.table.assign(binding, to: shortcut.id, overrides: overrides) {
        case .assigned(let updated, let displaced):
            settings.values.shortcutOverrides = updated
            if let binding, !displaced.isEmpty {
                ToastCenter.shared.info(
                    "\(displaced.joined(separator: ", ")) is now unassigned",
                    detail: "\(binding.display) belongs to \(shortcut.title) now."
                )
            }
        case .reserved(let holder):
            ToastCenter.shared.fail(nil, "\(binding?.display ?? "That key") belongs to \(holder)",
                                    detail: "It can't be reassigned, so \(shortcut.title) kept its key.")
        case .notAllowed:
            NSSound.beep()
        }
    }
}

/// One shortcut: its title, a "Custom" badge when changed, a warning when
/// another shortcut shares the key, the keycap, and a menu shown on hover.
private struct ShortcutRow: View {
    let shortcut: OctetShortcut
    let isCustom: Bool
    let conflict: String?
    @Binding var recording: Bool
    let save: (ShortcutBinding?) -> Void
    let reset: () -> Void
    @State private var hovered = false

    var body: some View {
        SettingsRow(title: shortcut.title, badge: isCustom ? "Custom" : nil) {
            HStack(spacing: 8) {
                if let conflict {
                    OctetIcon("exclamationmark.triangle.fill", size: 13)
                        .foregroundStyle(Theme.danger)
                        .help("Conflicts with \(conflict). The most recent binding wins.")
                        .accessibilityLabel("Conflicts with \(conflict)")
                }
                if recording {
                    ShortcutRecorder(
                        record: { binding in recording = false; save(binding) },
                        cancel: { recording = false }
                    )
                } else {
                    ShortcutKeycapPill(shortcut: shortcut) { recording = true }
                }
                rowMenu
            }
        }
        .onHover { hovered = $0 }
        .accessibilityElement(children: .contain)
    }

    /// Fades in with the pointer, T3 Code's quiet secondary actions.
    @ViewBuilder private var rowMenu: some View {
        if shortcut.customizable {
            Menu {
                Button("Reset to Default", action: reset).disabled(!isCustom)
                Button("Remove") { save(nil) }.disabled(shortcut.binding == nil)
            } label: {
                OctetIcon("ellipsis", size: 14)
                    .frame(width: 22, height: 22)
                    .contentShape(Rectangle())
            }
            .menuStyle(.button)
            .buttonStyle(.plain)
            .menuIndicator(.hidden)
            .fixedSize()
            .foregroundStyle(Theme.textTertiary)
            .opacity(hovered ? 1 : 0)
            .animation(.easeOut(duration: 0.12), value: hovered)
            .help("More for \(shortcut.title)")
            .accessibilityLabel("More for \(shortcut.title)")
        } else {
            // Holds the column so fixed rows' keycaps line up with the rest.
            Color.clear.frame(width: 22, height: 22)
        }
    }
}

/// The keys as a row of keycaps in a pill that records a new shortcut when
/// clicked; read only for keys the system or terminal owns.
private struct ShortcutKeycapPill: View {
    let shortcut: OctetShortcut
    let startRecording: () -> Void
    @State private var hovered = false

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: Theme.controlRadius)
        Button(action: startRecording) {
            HStack(spacing: 3) {
                if let keys = shortcut.keys {
                    ForEach(Array(Self.caps(keys).enumerated()), id: \.offset) { _, cap in
                        Keycap(text: cap)
                    }
                } else {
                    Text("Unassigned").font(Theme.uiFont).foregroundStyle(Theme.textTertiary)
                }
            }
            .padding(.horizontal, 6)
            .frame(minWidth: 64, minHeight: 28)
            .background(shape.fill(hovered ? Theme.hover : Color.clear))
            .overlay(shape.strokeBorder(hovered ? Theme.border : Color.clear, lineWidth: 1))
            .contentShape(shape)
        }
        .buttonStyle(.plain)
        .disabled(!shortcut.customizable)
        .onHover { hovered = $0 && shortcut.customizable }
        .animation(.easeOut(duration: 0.12), value: hovered)
        .help(shortcut.fixedReason ?? "Click to record a new shortcut")
        .accessibilityLabel(shortcut.keys.map { "\(shortcut.title), \($0)" } ?? "\(shortcut.title), unassigned")
        .accessibilityHint(shortcut.customizable ? "Records a new shortcut" : "")
    }

    /// "⌃⌘↓" as ⌃, ⌘, ↓; a range label ("⌘1…⌘8") stays one cap.
    static func caps(_ keys: String) -> [String] {
        guard !keys.contains("…") else { return [keys] }
        let modifiers: Set<Character> = ["⌃", "⌥", "⇧", "⌘"]
        var caps: [String] = []
        var rest = Substring(keys)
        while let first = rest.first, modifiers.contains(first) {
            caps.append(String(first))
            rest = rest.dropFirst()
        }
        if !rest.isEmpty { caps.append(String(rest)) }
        return caps
    }
}

/// The keycap while it listens: Esc cancels, Delete unassigns, and any key
/// with ⌘, ⌃ or ⌥ (or a function key alone) records. A click anywhere else
/// cancels too. Keys are caught before the menus see them, so recording ⌘T
/// doesn't also open a tab.
private struct ShortcutRecorder: View {
    let record: (ShortcutBinding?) -> Void
    let cancel: () -> Void
    @State private var held: ShortcutBinding.Modifiers = []
    @State private var hint: String?
    @State private var monitor: Any?

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: Theme.controlRadius)
        Text(label)
            .font(Theme.monoFont)
            .foregroundStyle(hint == nil ? Theme.textPrimary : Theme.danger)
            .lineLimit(1)
            .frame(width: 176, height: 28)
            .background(shape.fill(Theme.terminalBackground.opacity(0.7)))
            .overlay(shape.strokeBorder(Theme.accent.opacity(0.85), lineWidth: 1.5))
            .onAppear(perform: start)
            .onDisappear(perform: stop)
            .accessibilityLabel("Press shortcut")
            .accessibilityHint("Escape cancels, Delete unassigns")
    }

    private var label: String {
        if let hint { return hint }
        if held.isEmpty { return "Press shortcut" }
        return ShortcutBinding(key: "", modifiers: held).display + "…"
    }

    private func start() {
        monitor = NSEvent.addLocalMonitorForEvents(matching: [.keyDown, .flagsChanged, .leftMouseDown, .rightMouseDown]) { event in
            switch event.type {
            case .flagsChanged:
                held = Self.modifiers(event.modifierFlags)
                return event
            case .leftMouseDown, .rightMouseDown:
                cancel()
                return event
            default:
                handle(event)
                return nil
            }
        }
    }

    private func stop() {
        if let monitor { NSEvent.removeMonitor(monitor) }
        monitor = nil
    }

    private func handle(_ event: NSEvent) {
        let modifiers = Self.modifiers(event.modifierFlags)
        let plain = modifiers.isDisjoint(with: [.command, .control, .option])
        if event.keyCode == 53, plain { cancel(); return }
        if event.keyCode == 51 || event.keyCode == 117, plain { record(nil); return }
        guard let key = ShortcutBinding.key(keyCode: event.keyCode,
                                            unmodifiedCharacters: event.characters(byApplyingModifiers: [])) else { return }
        let binding = ShortcutBinding(key: key, modifiers: modifiers)
        guard binding.isAllowed else {
            NSSound.beep()
            hint = "Add ⌘, ⌃ or ⌥"
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.2) { hint = nil }
            return
        }
        record(binding)
    }

    static func modifiers(_ flags: NSEvent.ModifierFlags) -> ShortcutBinding.Modifiers {
        var result: ShortcutBinding.Modifiers = []
        if flags.contains(.command) { result.insert(.command) }
        if flags.contains(.control) { result.insert(.control) }
        if flags.contains(.option) { result.insert(.option) }
        if flags.contains(.shift) { result.insert(.shift) }
        return result
    }
}
