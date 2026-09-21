import SwiftUI

/// Claude Code's effort levels in its own colors: yellow low, blue medium,
/// pale blue high, lavender xhigh, coral max, and ultracode in purple over
/// shifting purple columns.
enum EffortStyle {
    static func color(_ level: String?) -> Color {
        switch level {
        case "none": Theme.textTertiary
        case "minimal": Color(hex: "E8D9A0")
        case "low": Color(hex: "FFDA58")
        case "medium", "thinking": Color(hex: "63ADFF")
        case "high": Color(hex: "B4D8FE")
        case "xhigh": Color(hex: "BBA2FF")
        case "max": Color(hex: "FFAE7C")
        case "ultracode", "ultra": Color(hex: "A275FF")
        default: Theme.textSecondary
        }
    }

    /// The level at the top of the scale, drawn on moving purple: Claude
    /// Code's "ultracode" and Codex's "ultra" both mean the model delegates
    /// work of its own.
    static func isTop(_ level: String?) -> Bool { level == "ultracode" || level == "ultra" }

    static let warning = "May use excessive tokens resulting in long response times or overthinking. Use sparingly for the hardest tasks."
    static let warned: Set<String> = ["max", "ultracode", "ultra"]

    /// One line under each level in the menu.
    static let detail: [String: String] = [
        "low": "Fastest, lightest thinking",
        "medium": "Quick, some thinking",
        "high": "Thorough",
        "xhigh": "Deep; best for most coding",
        "max": "Can overthink; for the hardest tasks",
        "ultracode": "xhigh + workflows",
        "ultra": "Maximum reasoning, with delegation",
    ]
}

/// Ultracode's backdrop: columns of purple that brighten and dim in a slow
/// travelling wave, drawn on a coarse grid like terminal cells.
struct UltracodeBackground: View {
    var cell = CGSize(width: 10, height: 12)
    private static let dark = NSColor(srgbRed: 0x49 / 255, green: 0x28 / 255, blue: 0x83 / 255, alpha: 1)
    private static let bright = NSColor(srgbRed: 0x97 / 255, green: 0x6F / 255, blue: 0xED / 255, alpha: 1)

    var body: some View {
        if NSWorkspace.shared.accessibilityDisplayShouldReduceMotion {
            Color(nsColor: Self.dark)
        } else {
            TimelineView(.animation) { context in
                let t = context.date.timeIntervalSinceReferenceDate
                Canvas { graphics, size in
                    let columns = Int(size.width / cell.width) + 1
                    let rows = Int(size.height / cell.height) + 1
                    for column in 0..<columns {
                        let x = Double(column)
                        for row in 0..<rows {
                            let y = Double(row)
                            // Two waves crossing, drifting right, with a little ripple per row.
                            let wave = sin(x * 0.23 - t * 1.6 + sin(y * 0.5 + t) * 0.35) * 0.6
                                + sin(x * 0.07 + t * 0.7) * 0.4
                            let level = (wave + 1) / 2
                            let color = Self.dark.blended(withFraction: level, of: Self.bright) ?? Self.dark
                            graphics.fill(Path(CGRect(x: CGFloat(column) * cell.width, y: CGFloat(row) * cell.height,
                                                      width: cell.width + 0.5, height: cell.height + 0.5)),
                                          with: .color(Color(nsColor: color)))
                        }
                    }
                }
            }
        }
    }
}

/// The composer's effort chip: the level in its color; ultracode shimmers.
struct EffortChip: View {
    let level: String?
    var implicit: String?
    let open: Bool
    @State private var hovered = false

    var body: some View {
        HStack(spacing: 5) {
            Text("Effort").font(Theme.captionFont).foregroundStyle(EffortStyle.isTop(level) ? .white.opacity(0.8) : Theme.textTertiary)
            if let level {
                EffortName(level: level, color: EffortStyle.isTop(level) ? .white : EffortStyle.color(level))
            } else {
                Text(implicit.map { "default · \($0)" } ?? "default")
                    .font(.system(size: 12, design: .monospaced))
                    .foregroundStyle(Theme.textSecondary)
            }
            OctetIcon("chevron.down", size: 11)
                .foregroundStyle(EffortStyle.isTop(level) ? .white.opacity(0.8) : Theme.textTertiary)
                .rotationEffect(.degrees(open ? 180 : 0))
        }
        .padding(.horizontal, 9)
        .frame(height: 24)
        .background {
            if EffortStyle.isTop(level) { UltracodeBackground(cell: CGSize(width: 6, height: 8)) }
            else { hovered || open ? Theme.hover : Theme.card }
        }
        .overlay(RoundedRectangle(cornerRadius: Theme.rowRadius + 1)
            .strokeBorder(open ? EffortStyle.color(level).opacity(0.7) : Theme.border, lineWidth: 1))
        .clipShape(RoundedRectangle(cornerRadius: Theme.rowRadius + 1))
        .onHover { hovered = $0 }
    }
}

/// Permission modes as Claude Code marks them in its footer: a glyph and a
/// color per mode, with "ask" (default) unmarked.
enum ModeStyle {
    static func color(_ mode: AgentSession.PermissionMode) -> Color {
        switch mode {
        case .default: Theme.textSecondary
        case .acceptEdits: Color(hex: "AF87FF")
        case .plan: Color(hex: "48968C")
        case .auto: Color(hex: "FFC107")
        case .bypassPermissions: Color(hex: "FF6B80")
        }
    }

    static func glyph(_ mode: AgentSession.PermissionMode) -> String {
        switch mode {
        case .default: ""
        case .plan: "⏸"
        default: "⏵⏵"
        }
    }

    /// The footer's wording, e.g. "plan mode on".
    static func label(_ mode: AgentSession.PermissionMode) -> String {
        switch mode {
        case .default: "ask before changes"
        case .acceptEdits: "accept edits on"
        case .plan: "plan mode on"
        case .auto: "auto mode on"
        case .bypassPermissions: "bypass permissions on"
        }
    }

    /// Shift-Tab's order; bypass stays out of the cycle and needs confirming.
    static let cycle: [AgentSession.PermissionMode] = [.default, .acceptEdits, .plan, .auto]
}

/// The mode chip: glyph and wording in the mode's color, like the footer.
struct ModeChip: View {
    let mode: AgentSession.PermissionMode
    let open: Bool
    @State private var hovered = false

    var body: some View {
        let tint = ModeStyle.color(mode)
        HStack(spacing: 5) {
            if !ModeStyle.glyph(mode).isEmpty {
                Text(ModeStyle.glyph(mode)).font(.system(size: 10.5))
            }
            Text(ModeStyle.label(mode)).font(.system(size: 12, design: .monospaced))
            OctetIcon("chevron.down", size: 11)
                .foregroundStyle(Theme.textTertiary)
                .rotationEffect(.degrees(open ? 180 : 0))
        }
        .foregroundStyle(tint)
        .padding(.horizontal, 9)
        .frame(height: 24)
        .background(mode == .default ? (hovered || open ? Theme.hover : Theme.card) : tint.opacity(hovered || open ? 0.2 : 0.12))
        .overlay(RoundedRectangle(cornerRadius: Theme.rowRadius + 1)
            .strokeBorder(mode == .default ? (open ? Theme.accent.opacity(0.6) : Theme.border) : tint.opacity(0.6), lineWidth: 1))
        .clipShape(RoundedRectangle(cornerRadius: Theme.rowRadius + 1))
        .onHover { hovered = $0 }
    }
}

/// Codex's sandboxes marked the way Claude Code's modes are: the safest one
/// unmarked, anything that writes without asking in its own color, and the
/// one with no sandbox at all in the same red as bypass.
enum SandboxStyle {
    static func color(_ profile: String?) -> Color {
        switch profile {
        case ":read-only": Color(hex: "48968C")
        case ":workspace": Color(hex: "AF87FF")
        case let id? where id.contains("danger"): Color(hex: "FF6B80")
        default: Theme.textSecondary
        }
    }

    static func glyph(_ profile: String?) -> String {
        switch profile {
        case ":read-only": "⏸"
        case nil: ""
        default: "⏵⏵"
        }
    }

    /// The chip's wording, in the footer's voice.
    static func label(_ profile: String?, profiles: [CodexPermissionProfile]) -> String {
        switch profile {
        case nil: return "sandbox from config"
        case ":read-only": return "read only"
        case ":workspace": return "workspace write on"
        case let id? where id.contains("danger"): return "full access on"
        default:
            let title = profiles.first { $0.id == profile }?.title ?? profile ?? ""
            return title.lowercased() + " on"
        }
    }

    /// Nil means whatever the person's own Codex config says, which Octet
    /// doesn't read; it is offered first so a thread can be left alone.
    static let unset = "__default__"
}

/// The sandbox chip, drawn like `ModeChip` so the two agents' composers read
/// the same.
struct SandboxChip: View {
    let profile: String?
    let profiles: [CodexPermissionProfile]
    let open: Bool
    @State private var hovered = false

    var body: some View {
        let tint = SandboxStyle.color(profile)
        let plain = profile == nil || profile == ":read-only"
        HStack(spacing: 5) {
            if !SandboxStyle.glyph(profile).isEmpty {
                Text(SandboxStyle.glyph(profile)).font(.system(size: 10.5))
            }
            Text(SandboxStyle.label(profile, profiles: profiles)).font(.system(size: 12, design: .monospaced))
            OctetIcon("chevron.down", size: 11)
                .foregroundStyle(Theme.textTertiary)
                .rotationEffect(.degrees(open ? 180 : 0))
        }
        .foregroundStyle(profile == nil ? Theme.textSecondary : tint)
        .padding(.horizontal, 9)
        .frame(height: 24)
        .background(plain ? (hovered || open ? Theme.hover : Theme.card) : tint.opacity(hovered || open ? 0.2 : 0.12))
        .overlay(RoundedRectangle(cornerRadius: Theme.rowRadius + 1)
            .strokeBorder(plain ? (open ? Theme.accent.opacity(0.6) : Theme.border) : tint.opacity(0.6), lineWidth: 1))
        .clipShape(RoundedRectangle(cornerRadius: Theme.rowRadius + 1))
        .onHover { hovered = $0 }
    }
}

/// Octet's effort panel: the level in its color, a slider across the levels
/// that fills in that color, and ultracode's moving purple at the far end.
/// Changes apply as you slide; Esc puts the previous level back.
struct EffortSliderPanel: View {
    let initial: String?
    /// Where the knob sits on "default": the model's own effort.
    let implicit: String?
    let apply: (String?) -> Void
    let close: () -> Void
    @State private var level: String?
    @FocusState private var focused: Bool

    /// The levels this agent offers, low to high. Claude Code's by default;
    /// Codex reports its own, which run to "ultra" where Claude has
    /// "ultracode".
    private let levels: [String]
    /// One line under the level, from the agent that named it.
    private let detail: [String: String]
    private let trackWidth: CGFloat = 260

    init(initial: String?, implicit: String?, levels: [String] = AgentSession.efforts,
         detail: [String: String] = EffortStyle.detail,
         apply: @escaping (String?) -> Void, close: @escaping () -> Void) {
        self.initial = initial
        self.implicit = implicit
        self.levels = levels
        self.detail = detail
        self.apply = apply
        self.close = close
        _level = State(initialValue: initial)
    }

    var body: some View {
        // On "default" the slider still shows where that lands.
        let shown = level ?? implicit
        let ultra = EffortStyle.isTop(shown)
        let tint = ultra ? Color.white : EffortStyle.color(shown)
        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Text("Effort")
                    .font(Theme.captionFont)
                    .foregroundStyle(ultra ? .white.opacity(0.75) : Theme.textTertiary)
                if let level {
                    EffortName(level: level, size: 14, color: tint)
                } else {
                    Text("default")
                        .font(.system(size: 14, weight: .semibold, design: .monospaced))
                        .foregroundStyle(Theme.textSecondary)
                }
                if level == nil, let implicit {
                    Text(implicit)
                        .font(.system(size: 12, design: .monospaced))
                        .foregroundStyle(EffortStyle.color(implicit).opacity(0.8))
                }
                Spacer()
                if level != nil {
                    Button("Default") { set(nil) }
                        .buttonStyle(.plain)
                        .font(Theme.captionFont)
                        .foregroundStyle(ultra ? .white.opacity(0.8) : Theme.textTertiary)
                }
            }
            slider(tint: tint, ultra: ultra, implicitOnly: level == nil)
            Text(level.flatMap { detail[$0] }
                 ?? implicit.map { "The model's default. \(detail[$0] ?? "")" } ?? "The agent picks its own effort")
                .font(Theme.captionFont)
                .foregroundStyle(ultra ? .white.opacity(0.8) : Theme.textSecondary)
                .contentTransition(.opacity)
            if let level, EffortStyle.warned.contains(level) {
                HStack(alignment: .top, spacing: 6) {
                    OctetIcon("exclamationmark.triangle.fill", size: 13)
                    Text(EffortStyle.warning)
                        .font(Theme.captionFont)
                        .fixedSize(horizontal: false, vertical: true)
                }
                .foregroundStyle(ultra ? .white : Color(hex: "FFC107"))
                .transition(.opacity)
                .accessibilityElement(children: .combine)
            }
        }
        .padding(14)
        .frame(width: trackWidth + 28)
        .background {
            ZStack {
                Theme.card
                UltracodeBackground().opacity(ultra ? 1 : 0)
            }
        }
        .overlay(RoundedRectangle(cornerRadius: 10).strokeBorder(ultra ? Color.white.opacity(0.2) : Theme.border, lineWidth: 1))
        .clipShape(RoundedRectangle(cornerRadius: 10))
        .shadow(color: .black.opacity(0.35), radius: 16, y: 6)
        .animation(.spring(response: 0.3, dampingFraction: 0.8), value: level)
        .focusable()
        .focusEffectDisabled()
        .focused($focused)
        .onAppear { DispatchQueue.main.async { focused = true } }
        .onKeyPress(.leftArrow) { step(-1); return .handled }
        .onKeyPress(.rightArrow) { step(1); return .handled }
        .onKeyPress(.return) { close(); return .handled }
        .onExitCommand {
            apply(initial)
            close()
        }
        .accessibilityElement()
        .accessibilityLabel("Effort")
        .accessibilityValue(level ?? "default")
        .accessibilityAdjustableAction { step($0 == .increment ? 1 : -1) }
    }

    private var isMax: Bool { (level ?? implicit) == "max" }

    private func slider(tint: Color, ultra: Bool, implicitOnly: Bool) -> some View {
        let count = CGFloat(levels.count - 1)
        let index = (level ?? implicit).flatMap { levels.firstIndex(of: $0) }
        let x = index.map { CGFloat($0) / count * trackWidth } ?? 0
        return ZStack(alignment: .leading) {
            Capsule().fill(ultra ? Color.white.opacity(0.25) : Theme.border).frame(width: trackWidth, height: 6)
            // Max keeps its rainbow in the name; the slider goes plain white.
            Capsule().fill(isMax ? Color.white : tint)
                .opacity(implicitOnly ? 0.45 : 1)
                .frame(width: index == nil ? 0 : max(6, x), height: 6)
            ForEach(0..<levels.count, id: \.self) { stop in
                Circle()
                    .fill(index.map { stop <= $0 } == true ? Color.clear : (ultra ? Color.white.opacity(0.5) : Theme.textTertiary))
                    .frame(width: 4, height: 4)
                    .offset(x: CGFloat(stop) / count * trackWidth - 2)
            }
            if index != nil {
                // A ring when the level is only the default; filled once chosen.
                let knob = isMax ? Color.white : tint
                Circle()
                    .fill(implicitOnly ? Theme.card : knob)
                    .overlay(Circle().strokeBorder(implicitOnly ? knob : Color.white.opacity(0.9), lineWidth: 2))
                    .frame(width: 16, height: 16)
                    .shadow(color: knob.opacity(implicitOnly ? 0 : 0.6), radius: 4)
                    .offset(x: x - 8)
            }
        }
        .frame(width: trackWidth, height: 18)
        .contentShape(Rectangle())
        .gesture(DragGesture(minimumDistance: 0).onChanged { drag in
            let stop = Int((min(1, max(0, drag.location.x / trackWidth)) * count).rounded())
            if levels[stop] != level { set(levels[stop]) }
        })
    }

    private func step(_ delta: Int) {
        let current = (level ?? implicit).flatMap { levels.firstIndex(of: $0) } ?? (delta > 0 ? -1 : levels.count)
        set(levels[min(levels.count - 1, max(0, current + delta))])
    }

    private func set(_ new: String?) {
        level = new
        apply(new)
    }
}

/// An effort level's name. "max" gives each letter its own color, and the
/// colors cycle along the word; others take their level color. Reduce
/// Motion holds the colors still.
struct EffortName: View {
    let level: String
    var size: CGFloat = 12
    var weight: Font.Weight = .semibold
    var color: Color

    var body: some View {
        if level == "max" {
            if NSWorkspace.shared.accessibilityDisplayShouldReduceMotion {
                letters(phase: 0)
            } else {
                TimelineView(.animation) { context in
                    letters(phase: context.date.timeIntervalSinceReferenceDate)
                }
            }
        } else {
            Text(level).font(.system(size: size, weight: weight, design: .monospaced)).foregroundStyle(color)
        }
    }

    private func letters(phase: Double) -> some View {
        HStack(spacing: 0) {
            ForEach(Array(level.enumerated()), id: \.offset) { index, character in
                Text(String(character))
                    .font(.system(size: size, weight: weight, design: .monospaced))
                    .foregroundStyle(Rainbow.color(at: Rainbow.hue(step: index, phase: phase)))
            }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(level)
    }
}

/// The max-effort rainbow: solid, distinct hues that cycle over time.
enum Rainbow {
    /// Letters and stops sit a sixth of the wheel apart; the wheel turns
    /// about once every three seconds.
    static func hue(step: Int, phase: Double) -> Double {
        (Double(step) / 6 + phase / 3).truncatingRemainder(dividingBy: 1)
    }

    static func color(at hue: Double) -> Color {
        Color(hue: hue, saturation: 0.62, brightness: 1)
    }
}
