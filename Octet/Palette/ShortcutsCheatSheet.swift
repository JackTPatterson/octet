import SwiftUI

/// Help › Keyboard Shortcuts: every key Octet knows, grouped as the Keyboard
/// settings page groups them, over the window like the palette. Typing
/// filters; Esc or a click outside closes it. It reads the same registry as
/// the menus, so a rebound key shows as it's bound now.
struct ShortcutsCheatSheet: View {
    let onClose: () -> Void
    @State private var query = ""
    @FocusState private var fieldFocused: Bool
    @ObservedObject private var shortcuts = ShortcutOverrides.shared

    private let columns = [GridItem(.flexible(), spacing: Theme.Space.xl, alignment: .top),
                           GridItem(.flexible(), spacing: Theme.Space.xl, alignment: .top)]

    var body: some View {
        ZStack(alignment: .top) {
            Theme.scrim
                .ignoresSafeArea()
                .onTapGesture(perform: close)
                .accessibilityHidden(true)
            panel
                .padding(.top, 56)
                .padding(.bottom, 32)
        }
        .onAppear { DispatchQueue.main.async { fieldFocused = true } }
    }

    private var panel: some View {
        let groups = OctetShortcut.groups(matching: query)
        return VStack(spacing: 0) {
            header
            Rectangle().fill(Theme.divider).frame(height: 1)
            ScrollView {
                if groups.isEmpty {
                    Text("No shortcuts match “\(query)”.")
                        .font(Theme.Text.body)
                        .foregroundStyle(Theme.textTertiary)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, Theme.Space.xxl)
                } else {
                    LazyVGrid(columns: columns, alignment: .leading, spacing: Theme.Space.xl) {
                        ForEach(groups, id: \.title) { group in
                            ShortcutGroupCard(title: group.title, shortcuts: group.shortcuts)
                        }
                    }
                    .padding(Theme.Space.xl)
                }
            }
            .frame(maxHeight: 560)
        }
        .frame(width: 720)
        .fixedSize(horizontal: false, vertical: true)
        .octetGlass(cornerRadius: Theme.Radius.sheet)
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Keyboard Shortcuts")
        .accessibilityAddTraits(.isModal)
    }

    private var header: some View {
        HStack(spacing: Theme.Space.md) {
            Text("Keyboard Shortcuts")
                .font(Theme.Text.title3)
                .foregroundStyle(Theme.textPrimary)
            Spacer(minLength: Theme.Space.lg)
            HStack(spacing: Theme.Space.sm) {
                OctetIcon("magnifyingglass", size: 14)
                    .foregroundStyle(Theme.textTertiary)
                TextField("Search shortcuts or keys", text: $query)
                    .textFieldStyle(.plain)
                    .font(Theme.Text.body)
                    .foregroundStyle(Theme.textPrimary)
                    .focused($fieldFocused)
                    .onKeyPress(.escape) {
                        if query.isEmpty { close() } else { query = "" }
                        return .handled
                    }
                    .accessibilityLabel("Search shortcuts")
            }
            .padding(.horizontal, Theme.Space.md)
            .frame(width: 240, height: 26)
            .background(Theme.card)
            .overlay(RoundedRectangle(cornerRadius: Theme.Radius.sm).strokeBorder(Theme.border, lineWidth: 1))
            .clipShape(RoundedRectangle(cornerRadius: Theme.Radius.sm))
            OctetButton(title: "Customize…", kind: .ghost, compact: true) {
                close()
                SettingsOpener.open(.keyboard)
            }
            .help("Change keys in Settings › Keyboard")
            OctetIconButton(icon: "xmark", help: "Close (esc)", action: close)
        }
        .padding(.horizontal, Theme.Space.xl)
        .frame(height: 52)
    }

    private func close() {
        onClose()
        OctetTerminalRuntime.focusTerminal()
    }
}

/// One group: its name, where its keys work when that isn't everywhere,
/// and a row per shortcut with its keys.
private struct ShortcutGroupCard: View {
    let title: String
    let shortcuts: [OctetShortcut]

    var body: some View {
        VStack(alignment: .leading, spacing: Theme.Space.xs) {
            HStack(alignment: .firstTextBaseline, spacing: Theme.Space.sm) {
                Text(title.uppercased())
                    .font(Theme.headerFont)
                    .kerning(0.4)
                    .foregroundStyle(Theme.textTertiary)
                    .accessibilityAddTraits(.isHeader)
                if let scope = shortcuts.first?.scope, shortcuts.allSatisfy({ $0.scope == scope }) {
                    Text(scope.whereText)
                        .font(Theme.Text.caption)
                        .foregroundStyle(Theme.textTertiary)
                        .lineLimit(1)
                }
            }
            .padding(.bottom, Theme.Space.xxs)
            ForEach(shortcuts) { shortcut in
                HStack(spacing: Theme.Space.md) {
                    Text(shortcut.title)
                        .font(Theme.Text.body)
                        .foregroundStyle(Theme.textSecondary)
                        .lineLimit(1)
                    Spacer(minLength: Theme.Space.md)
                    if let keys = shortcut.keys {
                        KeyCombo(keys: keys)
                    } else {
                        Text("Unassigned")
                            .font(Theme.Text.caption)
                            .foregroundStyle(Theme.textTertiary)
                    }
                }
                .frame(minHeight: 24)
                .accessibilityElement(children: .combine)
            }
        }
    }
}
