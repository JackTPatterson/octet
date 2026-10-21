import SwiftUI

// Octet's form inputs beyond the button, field, select and switch: a slider,
// a number field, a checkbox and a multi-line editor, after T3 Code's. They
// share OctetTextField's shell so every input in a form reads as one family,
// and none of them falls back to an AppKit-drawn control.

// MARK: - Field shell

extension View {
    /// The shell every Octet text input sits in: 28pt, the terminal ground
    /// at 70%, a hairline at rest and T3 Code's accent ring while focused.
    /// `invalid` draws the ring in the danger colour, so a field that won't
    /// take its value says so without a separate border.
    func octetFieldShell(focused: Bool, invalid: Bool = false, height: CGFloat? = 28) -> some View {
        let shape = RoundedRectangle(cornerRadius: Theme.controlRadius)
        return self
            .frame(height: height)
            .background(Theme.terminalBackground.opacity(0.7))
            .overlay(shape.strokeBorder(
                invalid ? Theme.danger : focused ? Theme.accent.opacity(0.85) : Theme.border,
                lineWidth: focused || invalid ? 1.5 : 1))
            .clipShape(shape)
            .animation(.easeOut(duration: 0.12), value: focused)
    }
}

// MARK: - Slider

/// Octet's slider, after T3 Code's `.settings-slider`: a 6pt track, the
/// accent up to the thumb and the rest muted, a 16pt thumb ringed in the
/// accent that grows a touch under the pointer and gives while pressed, and
/// the value in a small mono pill to its left. Arrow keys and VoiceOver's
/// adjust gestures move it a step.
struct OctetSlider: View {
    /// What VoiceOver calls it; the row title beside it.
    let label: String
    @Binding var value: Double
    let range: ClosedRange<Double>
    var step: Double = 1
    /// The whole control's width, pill included: T3 Code's `w-52`.
    var width: CGFloat = 208
    /// How the pill and VoiceOver read the value, e.g. "120%".
    var format: (Double) -> String = { "\(Int($0.rounded()))" }

    @State private var hovered = false
    @State private var pressed = false
    @FocusState private var focused: Bool
    @Environment(\.isEnabled) private var enabled

    private static let thumb: CGFloat = 16

    private var fraction: Double {
        let span = range.upperBound - range.lowerBound
        guard span > 0 else { return 0 }
        return min(1, max(0, (value - range.lowerBound) / span))
    }

    var body: some View {
        HStack(spacing: 12) {
            Text(format(value))
                .font(Theme.Text.mono(12, weight: .medium))
                .monospacedDigit()
                .foregroundStyle(Theme.textPrimary)
                .lineLimit(1)
                .padding(.horizontal, 8)
                .frame(minWidth: 48, minHeight: 24)
                .background(RoundedRectangle(cornerRadius: Theme.Radius.md).fill(Theme.cardSelected))
                .accessibilityHidden(true)
            track
        }
        .frame(width: width)
        .opacity(enabled ? 1 : 0.64)
        .accessibilityElement()
        .accessibilityLabel(label)
        .accessibilityValue(format(value))
        .accessibilityAdjustableAction { direction in
            nudge(direction == .increment ? 1 : -1)
        }
    }

    private var track: some View {
        GeometryReader { geometry in
            let side = Self.thumb
            let span = max(geometry.size.width - side, 1)
            // The fill runs to the thumb's centre, as T3 Code's offset does.
            let x = side / 2 + span * fraction
            ZStack(alignment: .leading) {
                Capsule()
                    .fill(Theme.textTertiary.opacity(0.22))
                    .overlay(Capsule().strokeBorder(Theme.border.opacity(0.55), lineWidth: 1))
                    .frame(height: 6)
                Capsule()
                    .fill(Theme.accent)
                    .frame(width: x, height: 6)
                Circle()
                    .fill(Theme.terminalBackground)
                    .overlay(Circle().strokeBorder(Theme.accent, lineWidth: 2))
                    // The focus ring sits outside the thumb, so it never
                    // reads as a thicker border.
                    .overlay(Circle().strokeBorder(Theme.accent.opacity(focused ? 0.35 : 0), lineWidth: 3).padding(-4))
                    .frame(width: side, height: side)
                    .shadow(color: .black.opacity(hovered ? 0.2 : 0.12), radius: hovered ? 1.5 : 1, y: 1)
                    .scaleEffect(pressed ? 0.94 : hovered ? 1.08 : 1)
                    .animation(.easeOut(duration: 0.12), value: hovered)
                    .animation(.easeOut(duration: 0.12), value: pressed)
                    .offset(x: x - side / 2)
            }
            .frame(height: geometry.size.height)
            .contentShape(Rectangle())
            .gesture(DragGesture(minimumDistance: 0)
                .onChanged { drag in
                    pressed = true
                    focused = true
                    set(fraction: (drag.location.x - side / 2) / span)
                }
                .onEnded { _ in pressed = false })
        }
        .frame(height: 24)
        .onHover { hovered = $0 && enabled }
        .focusable()
        .focusEffectDisabled()
        .focused($focused)
        .onKeyPress(.leftArrow) { nudge(-1); return .handled }
        .onKeyPress(.downArrow) { nudge(-1); return .handled }
        .onKeyPress(.rightArrow) { nudge(1); return .handled }
        .onKeyPress(.upArrow) { nudge(1); return .handled }
    }

    private func set(fraction: Double) {
        let clamped = min(1, max(0, fraction))
        let raw = range.lowerBound + clamped * (range.upperBound - range.lowerBound)
        let stepped = step > 0 ? (raw / step).rounded() * step : raw
        let next = min(range.upperBound, max(range.lowerBound, stepped))
        if next != value { value = next }
    }

    private func nudge(_ direction: Double) {
        let next = min(range.upperBound, max(range.lowerBound, value + direction * (step > 0 ? step : 1)))
        if next != value { value = next }
    }
}

// MARK: - Number field

/// Octet's number field, after T3 Code's: OctetTextField's shell split into
/// a − segment, the number (typed into directly, tabular, with its unit) and
/// a + segment. ↑/↓ in the number step it; anything typed applies on Return
/// or when focus leaves, clamped to the range.
struct OctetNumberField: View {
    /// What VoiceOver calls it; the row title beside it.
    let label: String
    @Binding var value: Double
    let range: ClosedRange<Double>
    var step: Double = 1
    /// After the number, e.g. "pt", "s", "min".
    var unit: String?
    /// How VoiceOver reads the value, e.g. "13 points".
    var spokenValue: ((Double) -> String)?
    var width: CGFloat = 132

    @State private var draft = ""
    @FocusState private var focused: Bool
    @Environment(\.isEnabled) private var enabled

    private var display: String {
        value == value.rounded() ? String(Int(value)) : String(format: "%g", value)
    }

    var body: some View {
        HStack(spacing: 0) {
            segment(icon: "minus", help: "Decrease \(label)", disabled: value <= range.lowerBound) { nudge(-1) }
            HStack(spacing: 3) {
                TextField("", text: $draft)
                    .textFieldStyle(.plain)
                    .font(Theme.interfaceFont(13).monospacedDigit())
                    .foregroundStyle(Theme.textPrimary)
                    .multilineTextAlignment(unit == nil ? .center : .trailing)
                    .fixedSize()
                    .focused($focused)
                    .onSubmit(commit)
                    .onKeyPress(.upArrow) { nudge(1); return .handled }
                    .onKeyPress(.downArrow) { nudge(-1); return .handled }
                if let unit {
                    Text(unit)
                        .font(Theme.interfaceFont(12))
                        .foregroundStyle(Theme.textTertiary)
                }
            }
            .frame(maxWidth: .infinity)
            segment(icon: "plus", help: "Increase \(label)", disabled: value >= range.upperBound) { nudge(1) }
        }
        .frame(width: width)
        .octetFieldShell(focused: focused)
        .opacity(enabled ? 1 : 0.64)
        .onAppear { draft = display }
        .onChange(of: value) { _, _ in draft = display }
        .onChange(of: focused) { _, now in if !now { commit() } }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(label)
        .accessibilityValue(spokenValue?(value) ?? [display, unit].compactMap { $0 }.joined(separator: " "))
        .accessibilityAdjustableAction { direction in nudge(direction == .increment ? 1 : -1) }
    }

    private func segment(icon: String, help: String, disabled: Bool, action: @escaping () -> Void) -> some View {
        NumberFieldSegment(icon: icon, help: help, action: action)
            .disabled(disabled)
    }

    private func commit() {
        let typed = draft.trimmingCharacters(in: .whitespaces)
        guard let number = Double(typed) else { draft = display; return }
        let stepped = step > 0 ? (number / step).rounded() * step : number
        let next = min(range.upperBound, max(range.lowerBound, stepped))
        if next != value { value = next }
        draft = display
    }

    private func nudge(_ direction: Double) {
        let next = min(range.upperBound, max(range.lowerBound, value + direction * step))
        if next != value { value = next }
    }
}

/// A − or + end of OctetNumberField: the field's full height, a hover fill.
private struct NumberFieldSegment: View {
    let icon: String
    let help: String
    let action: () -> Void
    @State private var hovered = false
    @Environment(\.isEnabled) private var enabled

    var body: some View {
        Button(action: action) {
            OctetIcon(icon, size: 13)
                .foregroundStyle(enabled ? (hovered ? Theme.textPrimary : Theme.textSecondary) : Theme.textMuted)
                .frame(width: 28, height: 28)
                .background(hovered && enabled ? Theme.hover : .clear)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hovered = $0 }
        .help(help)
        .accessibilityLabel(help)
    }
}

// MARK: - Checkbox

/// Octet's checkbox, after T3 Code's: a 16pt rounded square, bordered at
/// rest and filled with the accent and a tick when on, with its label beside
/// it. For a choice in a list (include this file, this option); a setting
/// that turns something on or off is OctetSwitchStyle.
struct OctetCheckboxStyle: ToggleStyle {
    func makeBody(configuration: Configuration) -> some View {
        OctetCheckbox(configuration: configuration)
    }
}

private struct OctetCheckbox: View {
    let configuration: ToggleStyleConfiguration
    @Environment(\.isEnabled) private var enabled
    @State private var hovered = false

    var body: some View {
        let on = configuration.isOn
        let shape = RoundedRectangle(cornerRadius: Theme.Radius.sm)
        Button {
            configuration.isOn.toggle()
        } label: {
            HStack(spacing: 8) {
                ZStack {
                    shape.fill(on ? Theme.accent : Theme.terminalBackground.opacity(0.7))
                    shape.strokeBorder(on ? Theme.accent : hovered ? Theme.textTertiary : Theme.border, lineWidth: 1)
                    if on {
                        OctetIcon("check", size: 11)
                            .foregroundStyle(Theme.onAccent)
                    }
                }
                .frame(width: 16, height: 16)
                .animation(.easeOut(duration: 0.1), value: on)
                configuration.label
                    .font(Theme.uiFont)
                    .foregroundStyle(Theme.textPrimary)
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hovered = $0 && enabled }
        .opacity(enabled ? 1 : 0.64)
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(.isButton)
        .accessibilityValue(on ? "Checked" : "Unchecked")
    }
}

// MARK: - Text editor

/// Octet's multi-line field: OctetTextField's shell around a plain text
/// editor, with the placeholder drawn where the first line goes.
struct OctetTextEditor: View {
    let placeholder: String
    @Binding var text: String
    var minHeight: CGFloat = 72
    var maxHeight: CGFloat? = 200
    var font: Font = Theme.uiFont
    /// Takes focus when it appears, e.g. a composer opened to write in.
    var autofocus = false
    @FocusState private var focused: Bool

    var body: some View {
        ZStack(alignment: .topLeading) {
            if text.isEmpty {
                Text(placeholder)
                    .font(font)
                    .foregroundStyle(Theme.textTertiary)
                    // Where TextEditor's own text container starts its line.
                    .padding(.leading, 5)
                    .padding(.top, 1)
                    .allowsHitTesting(false)
            }
            TextEditor(text: $text)
                .font(font)
                .foregroundStyle(Theme.textPrimary)
                .scrollContentBackground(.hidden)
                .focused($focused)
                .accessibilityLabel(placeholder)
        }
        .padding(.horizontal, 5)
        .padding(.vertical, 6)
        .frame(minHeight: minHeight, maxHeight: maxHeight)
        .octetFieldShell(focused: focused, height: nil)
        .onAppear { if autofocus { focused = true } }
    }
}
