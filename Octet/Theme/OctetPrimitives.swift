import SwiftUI

// MARK: - Icon buttons

/// A square icon button with no chrome until it's hovered, after T3 Code's
/// ghost icon buttons: 24pt (or 28pt `large`), a hover fill, and a fill
/// while `active` (a panel that's showing, a mode that's on).
struct OctetIconButton: View {
    let icon: String
    let help: String
    var active = false
    var large = false
    /// 22pt, for rows that are themselves 22pt, such as the terminal drawer's.
    var compact = false
    var tint: Color?
    let action: () -> Void
    @State private var hovered = false
    @Environment(\.isEnabled) private var enabled

    var body: some View {
        let side: CGFloat = large ? 28 : compact ? 22 : 24
        Button(action: action) {
            OctetIcon(icon, size: large ? 15 : compact ? 13 : 14)
                .foregroundStyle(tint ?? (active || hovered ? Theme.textPrimary : Theme.textSecondary))
                .frame(width: side, height: side)
                .background(RoundedRectangle(cornerRadius: Theme.controlRadius)
                    .fill(active ? Theme.cardSelected : hovered && enabled ? Theme.hover : .clear))
                .contentShape(Rectangle())
        }
        .buttonStyle(OctetPressStyle())
        .opacity(enabled ? 1 : 0.45)
        .onHover { hovered = $0 }
        .help(help)
        .accessibilityLabel(help)
    }
}

/// Buttons shrink a touch while pressed, as T3 Code's do.
struct OctetPressStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .scaleEffect(configuration.isPressed ? 0.97 : 1)
            .animation(.easeOut(duration: 0.08), value: configuration.isPressed)
    }
}

// MARK: - Segmented control

/// Octet's segmented control: a quiet track with the chosen segment raised
/// on it, after T3 Code's. Items are 24pt tall; the track pads them by 2.
struct OctetSegmented<Value: Hashable>: View {
    @Binding var selection: Value
    let items: [(value: Value, title: String)]
    /// Called when the pointer rests on a segment, e.g. to start loading it.
    var onHoverItem: ((Value) -> Void)?
    @State private var hovered: Value?

    var body: some View {
        HStack(spacing: 2) {
            ForEach(items, id: \.value) { item in
                let chosen = item.value == selection
                Button {
                    MotionPreferences.shared.perform(.sidebar) { selection = item.value }
                } label: {
                    Text(item.title)
                        .font(Theme.uiFontMedium)
                        .foregroundStyle(chosen || hovered == item.value ? Theme.textPrimary : Theme.textSecondary)
                        .lineLimit(1)
                        .padding(.horizontal, 10)
                        .frame(height: 24)
                        .background {
                            if chosen {
                                RoundedRectangle(cornerRadius: Theme.controlRadius)
                                    .fill(Theme.cardSelected)
                                    .shadow(color: .black.opacity(0.18), radius: 1, y: 0.5)
                            } else if hovered == item.value {
                                RoundedRectangle(cornerRadius: Theme.controlRadius).fill(Theme.hover.opacity(0.7))
                            }
                        }
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .onHover { inside in
                    hovered = inside ? item.value : (hovered == item.value ? nil : hovered)
                    if inside { onHoverItem?(item.value) }
                }
                .accessibilityAddTraits(chosen ? [.isButton, .isSelected] : .isButton)
            }
        }
        .padding(2)
        .background(RoundedRectangle(cornerRadius: Theme.popoverRadius).fill(Theme.card))
        .fixedSize()
    }
}

// MARK: - Two-click confirm

/// A button that asks before acting, in place: the first click turns its
/// label into "Confirm …?", a second click within three seconds acts.
/// Moving on (Escape, the time running out) puts it back. After T3 Code's
/// merge button, which confirms without a dialog.
struct OctetConfirmButton: View {
    let title: String
    var icon: String?
    /// The armed label, e.g. "Confirm merge?".
    let confirmTitle: String
    var kind: OctetButton.Kind = .primary
    var compact = true
    /// Shown while `busy`, e.g. "Merging…".
    var busyTitle: String?
    var busy = false
    let action: () -> Void
    @State private var armed = false
    @State private var disarm: DispatchWorkItem?

    var body: some View {
        OctetButton(title: busy ? (busyTitle ?? title) : armed ? confirmTitle : title,
                    icon: armed ? "check" : icon, kind: kind, compact: compact) {
            guard !busy else { return }
            if armed {
                setArmed(false)
                action()
            } else {
                setArmed(true)
            }
        }
        .animation(MotionPreferences.shared.animation(.sidebar), value: armed)
        .onExitCommand { setArmed(false) }
        .onDisappear { disarm?.cancel() }
    }

    private func setArmed(_ value: Bool) {
        disarm?.cancel()
        armed = value
        guard value else { return }
        let work = DispatchWorkItem { armed = false }
        disarm = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 3, execute: work)
    }
}

// MARK: - Copyable text

/// Monospaced text that copies itself on click and says so for a moment,
/// e.g. `gh pr checkout 12` or a branch name.
struct OctetCopyText: View {
    let text: String
    var display: String?
    var help: String?
    @State private var copied = false
    @State private var hovered = false

    var body: some View {
        Button {
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(text, forType: .string)
            withAnimation(.easeOut(duration: 0.15)) { copied = true }
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.2) {
                withAnimation(.easeOut(duration: 0.15)) { copied = false }
            }
        } label: {
            Text(copied ? "Copied" : display ?? text)
                .font(Theme.monoFont)
                .foregroundStyle(copied ? Theme.textPrimary : Theme.textSecondary)
                .lineLimit(1)
                .truncationMode(.middle)
                .padding(.horizontal, 4)
                .padding(.vertical, 2)
                .background(RoundedRectangle(cornerRadius: Theme.Radius.sm).fill(hovered ? Theme.hover : .clear))
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hovered = $0 }
        .help(help ?? "Copy \(text)")
    }
}

// MARK: - Collapsible section

/// A section with a quiet heading that folds its content, after T3 Code's
/// pull request sections: a small muted title and a chevron that turns.
struct OctetCollapsible<Content: View, Trailing: View>: View {
    let title: String
    @Binding var open: Bool
    @ViewBuilder var trailing: () -> Trailing
    @ViewBuilder var content: () -> Content
    @State private var hovered = false

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 6) {
                Button {
                    MotionPreferences.shared.perform(.sidebar) { open.toggle() }
                } label: {
                    HStack(spacing: 6) {
                        Text(title)
                            .font(Theme.uiFontMedium)
                            .foregroundStyle(hovered ? Theme.textPrimary : Theme.textSecondary)
                        OctetIcon("chevron.right", size: 11)
                            .foregroundStyle(Theme.textTertiary)
                            .rotationEffect(.degrees(open ? 90 : 0))
                    }
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .onHover { hovered = $0 }
                .accessibilityValue(open ? "Expanded" : "Collapsed")
                Spacer(minLength: 4)
                trailing()
            }
            .padding(.vertical, 10)
            if open { content() }
        }
    }
}

extension OctetCollapsible where Trailing == EmptyView {
    init(title: String, open: Binding<Bool>, @ViewBuilder content: @escaping () -> Content) {
        self.init(title: title, open: open, trailing: { EmptyView() }, content: content)
    }
}

// MARK: - Shelf header

/// T3 Code's shelf header: an icon, a 12pt label, a count, then a hairline
/// to the edge, so sections read as shelves rather than boxed cards.
struct OctetShelfHeader: View {
    let icon: String
    let title: String
    let count: Int
    var tint: Color?

    var body: some View {
        HStack(spacing: 6) {
            OctetIcon(icon, size: 12).foregroundStyle(tint ?? Theme.textSecondary)
            Text(title).font(Theme.interfaceFont(12, weight: .medium))
            Text("\(count)").font(Theme.captionFont.monospacedDigit()).foregroundStyle(Theme.textTertiary)
            Rectangle().fill(Theme.divider).frame(height: 1).padding(.leading, 4)
        }
        .foregroundStyle(Theme.textSecondary)
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(.isHeader)
    }
}

// MARK: - Avatars

/// A person's GitHub avatar, round, with their initial until it loads.
struct GitHubAvatar: View {
    let login: String
    var size: CGFloat = 16

    var body: some View {
        AsyncImage(url: URL(string: "https://github.com/\(login).png?size=\(Int(size * 2))")) { image in
            image.resizable().interpolation(.high)
        } placeholder: {
            Text(login.prefix(1).uppercased())
                .font(.system(size: size * 0.55, weight: .semibold))
                .foregroundStyle(Theme.textSecondary)
                .frame(width: size, height: size)
                .background(Theme.cardSelected)
        }
        .frame(width: size, height: size)
        .clipShape(Circle())
        .accessibilityHidden(true)
    }
}

// MARK: - Switch

/// Octet's switch, after T3 Code's: a 30×18 pill, the accent when on, a
/// white thumb that stretches a little while pressed.
struct OctetSwitchStyle: ToggleStyle {
    func makeBody(configuration: Configuration) -> some View {
        OctetSwitch(configuration: configuration)
    }
}

private struct OctetSwitch: View {
    let configuration: ToggleStyleConfiguration
    @Environment(\.isEnabled) private var enabled
    @State private var pressed = false

    var body: some View {
        let on = configuration.isOn
        // The label is for VoiceOver: rows say what a switch is for, and
        // labelsHidden() reaches only the system's own styles.
        HStack(spacing: 8) {
            ZStack(alignment: on ? .trailing : .leading) {
                Capsule().fill(on ? Theme.accent : Theme.cardSelected)
                Capsule()
                    // Dark on the accent, as T3 Code's thumb is: readable
                    // whatever colour the theme's accent is.
                    .fill(on ? Theme.terminalBackground : Theme.textSecondary)
                    .shadow(color: .black.opacity(0.25), radius: 1, y: 0.5)
                    .frame(width: pressed ? 16 : 14, height: 14)
                    .padding(2)
            }
            .frame(width: 30, height: 18)
            .animation(.easeOut(duration: 0.15), value: on)
            .animation(.easeOut(duration: 0.1), value: pressed)
            .contentShape(Capsule())
            .onTapGesture { configuration.isOn.toggle() }
            .onLongPressGesture(minimumDuration: 0, maximumDistance: 8, pressing: { pressed = $0 }, perform: {})
        }
        .opacity(enabled ? 1 : 0.64)
        .background { configuration.label.hidden() }
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(.isButton)
        .accessibilityValue(on ? "On" : "Off")
        .accessibilityAction { configuration.isOn.toggle() }
    }
}

// MARK: - Select

/// Octet's dropdown for a choice among several, after T3 Code's select: a
/// 28pt bordered trigger with the current choice and a small chevron, its
/// menu the system's (keyboard, type-to-select and VoiceOver come free).
struct OctetSelect<Value: Hashable>: View {
    @Binding var selection: Value
    let options: [(value: Value, title: String)]
    var width: CGFloat?
    @State private var hovered = false

    private var current: String {
        options.first { $0.value == selection }?.title ?? ""
    }

    var body: some View {
        Menu {
            Picker("", selection: $selection) {
                ForEach(options, id: \.value) { option in Text(option.title).tag(option.value) }
            }
            .pickerStyle(.inline)
            .labelsHidden()
        } label: {
            HStack(spacing: 6) {
                Text(current)
                    .font(Theme.Text.transcript)
                    .foregroundStyle(Theme.textPrimary)
                    .lineLimit(1)
                    .truncationMode(.tail)
                Spacer(minLength: 4)
                OctetIcon("chevron.down", size: 10).foregroundStyle(Theme.textTertiary)
            }
            .padding(.horizontal, 10)
            .frame(width: width, height: 28)
            .background(RoundedRectangle(cornerRadius: Theme.popoverRadius)
                .fill(hovered ? Theme.hover : Theme.terminalBackground.opacity(0.55)))
            .overlay(RoundedRectangle(cornerRadius: Theme.popoverRadius).strokeBorder(Theme.border, lineWidth: 1))
            .overlay(alignment: .top) {
                Rectangle().fill(Color.white.opacity(0.06)).frame(height: 1).padding(.horizontal, Theme.popoverRadius)
            }
            .contentShape(Rectangle())
        }
        .menuStyle(.button)
        .buttonStyle(.plain)
        .menuIndicator(.hidden)
        .fixedSize(horizontal: width == nil, vertical: true)
        .onHover { hovered = $0 }
        .accessibilityValue(current)
    }
}

// MARK: - Glass

extension View {
    /// T3 Code's floating surfaces (dialogs, the palette, toasts): frosted
    /// glass tinted by the theme, a hairline border, a faint lit top edge
    /// and a deep, soft shadow beneath rather than around.
    func octetGlass(cornerRadius: CGFloat, fill: Color = Theme.sidebar) -> some View {
        let shape = RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
        return self
            .background {
                ZStack {
                    shape.fill(.ultraThinMaterial)
                    shape.fill(fill.opacity(0.86))
                }
            }
            .clipShape(shape)
            .overlay(shape.strokeBorder(Theme.border, lineWidth: 1))
            .overlay(alignment: .top) {
                Rectangle().fill(Color.white.opacity(0.05)).frame(height: 1).padding(.horizontal, cornerRadius)
            }
            .shadow(color: .black.opacity(0.55), radius: 34, y: 18)
    }
}
