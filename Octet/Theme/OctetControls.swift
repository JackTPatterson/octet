import AppKit
import SwiftUI

// Octet's own controls, drawn from Theme instead of the system's, so every
// surface matches the chrome in any theme.

/// Forces SwiftUI's backing scroll view to use the compact overlay scroller.
/// This keeps the visible thumb as a rounded pill even when macOS is set to
/// always show legacy scroll bars. The system still owns scrolling, sizing,
/// accessibility and pointer interaction.
private final class OctetScrollProbeView: NSView {
    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        DispatchQueue.main.async { [weak self] in self?.configureScrollView() }
    }

    private func configureScrollView() {
        var ancestor = superview
        while let view = ancestor {
            if let scrollView = view as? NSScrollView {
                scrollView.scrollerStyle = .overlay
                scrollView.autohidesScrollers = true
                scrollView.verticalScroller?.controlSize = .small
                scrollView.horizontalScroller?.controlSize = .small
                return
            }
            ancestor = view.superview
        }
    }
}

private struct OctetScrollProbe: NSViewRepresentable {
    func makeNSView(context: Context) -> NSView { OctetScrollProbeView(frame: .zero) }
    func updateNSView(_ nsView: NSView, context: Context) {}
}

extension View {
    /// A compact capsule thumb with no permanent gutter or square-ended track.
    func octetScrollIndicators() -> some View {
        background(OctetScrollProbe().frame(width: 0, height: 0))
    }
}

// MARK: - Panels and interactive lists

/// The shared surface for UI that docks against the composer. Keeping the
/// fill and separator here prevents slash commands, file references, queued
/// messages and approvals from slowly developing different panel chrome.
struct OctetPalettePanel<Content: View>: View {
    enum Style { case docked, floating }
    enum DividerEdge { case top, bottom, none }

    var style: Style = .docked
    var divider: DividerEdge = .top
    var clips = true
    @ViewBuilder let content: () -> Content

    var body: some View {
        content()
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Theme.card)
            .overlay(alignment: divider == .bottom ? .bottom : .top) {
                if style == .docked, divider != .none {
                    Rectangle().fill(Theme.divider).frame(height: 1)
                }
            }
            .modifier(PaletteSurfaceModifier(floating: style == .floating, clips: clips))
    }
}

private struct PaletteSurfaceModifier: ViewModifier {
    let floating: Bool
    let clips: Bool
    @ViewBuilder
    func body(content: Content) -> some View {
        if floating {
            content
                .clipShape(RoundedRectangle(cornerRadius: 7))
                .overlay(RoundedRectangle(cornerRadius: 7).strokeBorder(Theme.border, lineWidth: 1))
                .shadow(color: .black.opacity(0.35), radius: 14, y: 6)
        } else if clips {
            content.clipped()
        } else {
            content
        }
    }
}

/// One implementation of the moving selection used by command palettes.
/// Mouse, keyboard-selected state, animation, hit targets and accessibility
/// now behave identically anywhere this list is used.
struct OctetAnimatedList<Item: Identifiable, Row: View>: View where Item.ID: Hashable {
    let items: [Item]
    let highlighted: Int
    var horizontalPadding: CGFloat = 8
    var verticalPadding: CGFloat = 5
    let highlight: (Int) -> Void
    let choose: (Item) -> Void
    @ViewBuilder let row: (Item, Bool) -> Row

    @ObservedObject private var motion = MotionPreferences.shared
    @Namespace private var selection

    var body: some View {
        VStack(alignment: .leading, spacing: 1) {
            ForEach(Array(items.enumerated()), id: \.element.id) { index, item in
                row(item, index == highlighted)
                    .padding(.horizontal, horizontalPadding)
                    .padding(.vertical, verticalPadding)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background {
                        if index == highlighted {
                            RoundedRectangle(cornerRadius: Theme.rowRadius)
                                .fill(Theme.cardSelected)
                                .matchedGeometryEffect(id: "highlight", in: selection)
                        }
                    }
                    .contentShape(Rectangle())
                    .id(item.id)
                    .onHover { hovering in
                        if hovering, index != highlighted { highlight(index) }
                    }
                    .onTapGesture { choose(item) }
                    .transition(motion.animates(.palette)
                        ? .opacity.combined(with: .offset(y: 6))
                        : .identity)
                    .accessibilityElement(children: .combine)
                    .accessibilityAddTraits(index == highlighted ? [.isButton, .isSelected] : .isButton)
                    .accessibilityAction { choose(item) }
            }
        }
        .animation(motion.animation(.palette, .smooth(duration: 0.14)), value: highlighted)
        .animation(motion.animation(.palette, .smooth(duration: 0.14)), value: items.map(\.id))
    }
}

/// A themed push button.
struct OctetButton: View {
    enum Kind { case primary, secondary, ghost, destructive }

    let title: String
    var icon: String?
    var kind: Kind = .secondary
    var compact = false
    let action: () -> Void
    @Environment(\.isEnabled) private var enabled
    @State private var hovered = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: 5) {
                if let icon { OctetIcon(icon, size: compact ? 12 : 14) }
                Text(title).font(Theme.uiFontMedium).lineLimit(1)
            }
            .foregroundStyle(foreground)
            .padding(.horizontal, compact ? 9 : 14)
            .frame(height: compact ? 24 : 28)
            .background {
                RoundedRectangle(cornerRadius: Theme.rowRadius + 1).fill(background)
                if kind == .secondary {
                    RoundedRectangle(cornerRadius: Theme.rowRadius + 1).strokeBorder(Theme.border, lineWidth: 1)
                }
            }
            .opacity(enabled ? 1 : 0.45)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hovered = $0 && enabled }
    }

    private var foreground: Color {
        switch kind {
        case .primary: Theme.onAccent
        case .destructive: .white
        case .secondary: Theme.textPrimary
        case .ghost: hovered ? Theme.textPrimary : Theme.textSecondary
        }
    }

    private var background: Color {
        switch kind {
        case .primary: Theme.accent.opacity(hovered ? 0.85 : 1)
        case .destructive: Color(hex: "c62a2f").opacity(hovered ? 0.85 : 1)
        case .secondary: hovered ? Theme.hover : Theme.card
        case .ghost: hovered ? Theme.hover : .clear
        }
    }
}

/// A themed single-line text field.
struct OctetTextField: View {
    let placeholder: String
    @Binding var text: String
    var secure = false
    var onSubmit: () -> Void = {}
    @FocusState private var focused: Bool

    var body: some View {
        ZStack(alignment: .leading) {
            if text.isEmpty {
                Text(placeholder)
                    .font(Theme.uiFont)
                    .foregroundStyle(Theme.textTertiary)
                    .allowsHitTesting(false)
            }
            Group {
                if secure { SecureField("", text: $text) }
                else { TextField("", text: $text) }
            }
                .textFieldStyle(.plain)
                .font(Theme.uiFont)
                .foregroundStyle(Theme.textPrimary)
                .focused($focused)
                .onSubmit(onSubmit)
                .accessibilityLabel(placeholder)
        }
        .padding(.horizontal, 9)
        .frame(height: 28)
        .background(Theme.terminalBackground)
        .overlay(RoundedRectangle(cornerRadius: Theme.rowRadius + 1)
            .strokeBorder(focused ? Theme.accent.opacity(0.7) : Theme.border, lineWidth: 1))
        .clipShape(RoundedRectangle(cornerRadius: Theme.rowRadius + 1))
    }
}

// MARK: - Dropdowns

/// One choice in an Octet dropdown.
struct OctetDropdownOption: Identifiable, Equatable {
    let id: String
    let title: String
    var detail: String?
    /// Options sharing a section sit under one heading.
    var section: String?
    /// Drawn in red: a choice with real risk.
    var dangerous = false
    /// The option's own color, e.g. a mode's; overrides the default text color.
    var tint: Color?
    /// A short mark before the title, e.g. a mode's glyph.
    var glyph: String?
    /// Drawn over ultracode's moving purple columns.
    var shimmer = false
}

/// Everything a dropdown menu needs; the host draws it above all content.
struct OctetDropdownSpec {
    let id: String
    let options: [OctetDropdownOption]
    let selected: String
    let select: (String) -> Void
    /// When set, the menu opens as an autocomplete and filters as the person types.
    var searchPlaceholder: String? = nil
    /// A panel drawn instead of the option list; it gets a close action.
    var panel: ((@escaping () -> Void) -> AnyView)?
}

/// Which dropdown is open, shared by the buttons and the host.
final class OctetDropdownState: ObservableObject {
    @Published var openId: String?
    fileprivate var specs: [String: OctetDropdownSpec] = [:]
}

private struct DropdownAnchorKey: PreferenceKey {
    static var defaultValue: [String: Anchor<CGRect>] = [:]
    static func reduce(value: inout [String: Anchor<CGRect>], nextValue: () -> [String: Anchor<CGRect>]) {
        value.merge(nextValue()) { $1 }
    }
}

/// The closed state: current value and a chevron. Clicking opens its menu,
/// which the nearest `octetDropdownHost()` draws.
struct OctetDropdown: View {
    let spec: OctetDropdownSpec
    var label: String
    @ObservedObject var state: OctetDropdownState
    @State private var hovered = false

    var body: some View {
        let open = state.openId == spec.id
        let currentOption = spec.options.first { $0.id == spec.selected }
        let current = currentOption?.title ?? spec.selected
        let dangerous = currentOption?.dangerous == true
        Button {
            state.specs[spec.id] = spec
            state.openId = open ? nil : spec.id
        } label: {
            HStack(spacing: 5) {
                Text(current)
                    .font(Theme.uiFont)
                    .foregroundStyle(dangerous ? Theme.danger : Theme.textPrimary)
                    .lineLimit(1)
                OctetIcon("chevron.down", size: 11)
                    .foregroundStyle(Theme.textTertiary)
                    .rotationEffect(.degrees(open ? 180 : 0))
            }
            .padding(.horizontal, 9)
            .frame(height: 24)
            .background(open || hovered ? Theme.hover : Theme.card)
            .overlay(RoundedRectangle(cornerRadius: Theme.rowRadius + 1)
                .strokeBorder(dangerous ? Theme.danger.opacity(0.7) : open ? Theme.accent.opacity(0.6) : Theme.border, lineWidth: 1))
            .clipShape(RoundedRectangle(cornerRadius: Theme.rowRadius + 1))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hovered = $0 }
        .anchorPreference(key: DropdownAnchorKey.self, value: .bounds) { [spec.id: $0] }
        .onAppear { state.specs[spec.id] = spec }
        .onChange(of: spec.selected) { _, _ in state.specs[spec.id] = spec }
        .onChange(of: spec.options.map(\.id)) { _, _ in state.specs[spec.id] = spec }
        .accessibilityLabel(label)
        .accessibilityValue(current)
        .accessibilityHint("Opens a menu")
    }
}

/// Any label that opens a dropdown or panel from the host, for controls
/// that draw their own closed state.
struct OctetDropdownAnchor<Label: View>: View {
    let spec: OctetDropdownSpec
    @ObservedObject var state: OctetDropdownState
    @ViewBuilder let label: (Bool) -> Label

    var body: some View {
        let open = state.openId == spec.id
        Button {
            state.specs[spec.id] = spec
            state.openId = open ? nil : spec.id
        } label: {
            label(open).contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .anchorPreference(key: DropdownAnchorKey.self, value: .bounds) { [spec.id: $0] }
        .onAppear { state.specs[spec.id] = spec }
        .onChange(of: spec.selected) { _, _ in state.specs[spec.id] = spec }
        .onChange(of: spec.options.map(\.id)) { _, _ in state.specs[spec.id] = spec }
    }
}

extension View {
    /// Draws whichever dropdown is open above this view's content, with a
    /// click-away layer behind it. Menus open upward when there's no room
    /// below.
    func octetDropdownHost(_ state: OctetDropdownState) -> some View {
        overlayPreferenceValue(DropdownAnchorKey.self) { anchors in
            DropdownLayer(state: state, anchors: anchors)
        }
    }
}

/// Watches the open state itself: the preference closure alone only reruns
/// when anchors move, not when a menu opens.
private struct DropdownLayer: View {
    @ObservedObject var state: OctetDropdownState
    let anchors: [String: Anchor<CGRect>]

    var body: some View {
        GeometryReader { proxy in
            if let id = state.openId, let anchor = anchors[id], let spec = state.specs[id] {
                let rect = proxy[anchor]
                ZStack(alignment: .topLeading) {
                    Color.black.opacity(0.001)
                        .contentShape(Rectangle())
                        .onTapGesture { state.openId = nil }
                    // Room on the roomier side; long menus scroll within it.
                    let room = max(proxy.size.height - rect.maxY, rect.minY) - 12
                    Group {
                        if let panel = spec.panel {
                            panel { state.openId = nil }
                        } else {
                            DropdownMenu(spec: spec, maxHeight: room) { state.openId = nil }
                        }
                    }
                        .fixedSize()
                        .alignmentGuide(.leading) { _ in -rect.minX }
                        .alignmentGuide(.top) { menu in
                            let below = rect.maxY + 4
                            return below + menu.height <= proxy.size.height ? -below : -(rect.minY - 4 - menu.height)
                        }
                }
                .frame(width: proxy.size.width, height: proxy.size.height, alignment: .topLeading)
            }
        }
    }
}

private struct DropdownMenu: View {
    let spec: OctetDropdownSpec
    var maxHeight: CGFloat = .infinity
    let close: () -> Void
    @State private var highlighted: String?
    @State private var query = ""
    @FocusState private var focus: FocusTarget?

    private enum FocusTarget { case menu, search }

    private var filtered: [OctetDropdownOption] {
        let needle = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !needle.isEmpty else { return spec.options }
        return spec.options.filter { option in
            [option.title, option.id, option.detail ?? "", option.section ?? ""]
                .contains { FuzzyMatcher.match(needle, in: $0) != nil }
        }
    }

    var body: some View {
        VStack(spacing: 0) {
            if let placeholder = spec.searchPlaceholder {
                HStack(spacing: 7) {
                    OctetIcon("magnifyingglass", size: 12).foregroundStyle(Theme.textTertiary)
                    TextField(placeholder, text: $query)
                        .textFieldStyle(.plain)
                        .font(Theme.uiFont)
                        .foregroundStyle(Theme.textPrimary)
                        .focused($focus, equals: .search)
                        .onSubmit { choose(highlighted ?? filtered.first?.id ?? spec.selected) }
                }
                .padding(.horizontal, 9)
                .frame(height: 32)
                .overlay(alignment: .bottom) { Rectangle().fill(Theme.divider).frame(height: 1) }
            }
            ViewThatFits(in: .vertical) {
                options
                ScrollView { options }.frame(height: maxHeight)
            }
        }
        .frame(maxHeight: maxHeight)
        .modifier(DropdownPaletteSurface())
        .focusable()
        .focusEffectDisabled()
        .focused($focus, equals: .menu)
        .onAppear {
            highlighted = spec.selected
            DispatchQueue.main.async { focus = spec.searchPlaceholder == nil ? .menu : .search }
        }
        .onChange(of: query) { _, _ in highlighted = filtered.first?.id }
        .onKeyPress(.upArrow) { move(-1); return .handled }
        .onKeyPress(.downArrow) { move(1); return .handled }
        .onKeyPress(.return) { choose(highlighted ?? spec.selected); return .handled }
        .onExitCommand(perform: close)
    }

    private var options: some View {
        VStack(alignment: .leading, spacing: 1) {
            if filtered.isEmpty {
                Text("No matching models")
                    .font(Theme.uiFont)
                    .foregroundStyle(Theme.textTertiary)
                    .padding(12)
                    .frame(minWidth: 220, alignment: .leading)
            }
            ForEach(Array(filtered.enumerated()), id: \.element.id) { index, option in
                let selected = option.id == spec.selected
                if let section = option.section, index == 0 || filtered[index - 1].section != section {
                    Text(section.uppercased())
                        .font(Theme.headerFont)
                        .kerning(0.4)
                        .foregroundStyle(Theme.textTertiary)
                        .padding(.horizontal, 8)
                        .padding(.top, index == 0 ? 4 : 10)
                        .padding(.bottom, 2)
                        .accessibilityAddTraits(.isHeader)
                }
                HStack(spacing: 8) {
                    OctetIcon("checkmark", size: 12)
                        .foregroundStyle(Theme.accent)
                        .opacity(selected ? 1 : 0)
                    VStack(alignment: .leading, spacing: 1) {
                        HStack(spacing: 5) {
                            if let glyph = option.glyph, !glyph.isEmpty { Text(glyph).font(.system(size: 10.5)) }
                            Text(option.title).font(Theme.uiFont)
                        }
                        .foregroundStyle(option.shimmer ? .white : option.dangerous ? Theme.danger : option.tint ?? Theme.textPrimary)
                        if let detail = option.detail {
                            Text(detail).font(Theme.captionFont)
                                .foregroundStyle(option.shimmer ? .white.opacity(0.75) : Theme.textTertiary)
                        }
                    }
                    Spacer(minLength: 12)
                }
                .padding(.horizontal, 8)
                .padding(.vertical, 5)
                .frame(minWidth: 170, alignment: .leading)
                .background {
                    if option.shimmer {
                        UltracodeBackground(cell: CGSize(width: 6, height: 8))
                            .overlay(Color.white.opacity(highlighted == option.id ? 0.12 : 0))
                    } else if highlighted == option.id {
                        Theme.cardSelected
                    }
                }
                .clipShape(RoundedRectangle(cornerRadius: Theme.rowRadius))
                .contentShape(Rectangle())
                .onHover { if $0 { highlighted = option.id } }
                .onTapGesture { choose(option.id) }
                .accessibilityElement(children: .combine)
                .accessibilityAddTraits(selected ? [.isButton, .isSelected] : .isButton)
                .accessibilityAction { choose(option.id) }
            }
        }
        .padding(4)
    }

    private func move(_ delta: Int) {
        let ids = filtered.map(\.id)
        guard !ids.isEmpty else { return }
        let current = ids.firstIndex(of: highlighted ?? spec.selected) ?? 0
        highlighted = ids[(current + delta + ids.count) % ids.count]
    }

    private func choose(_ id: String) {
        spec.select(id)
        close()
    }
}

/// Adapts the shared palette surface without changing DropdownMenu's focus
/// and sizing semantics.
private struct DropdownPaletteSurface: ViewModifier {
    func body(content: Content) -> some View {
        OctetPalettePanel(style: .floating, divider: .none) { content }
    }
}

/// A stepped slider in Octet's style: a track with a dot per step, a knob
/// you drag or click to, and the chosen step's name beside it. Arrow keys
/// and VoiceOver's adjust gestures move it one step.
struct OctetStepSlider: View {
    let label: String
    let steps: [String]
    @Binding var index: Int
    var width: CGFloat = 110
    @State private var hovering = false
    @FocusState private var focused: Bool

    var body: some View {
        let count = max(steps.count - 1, 1)
        HStack(spacing: 8) {
            GeometryReader { geometry in
                let span = geometry.size.width - 12
                let x = 6 + span * CGFloat(index) / CGFloat(count)
                ZStack(alignment: .leading) {
                    Capsule().fill(Theme.border).frame(height: 4).padding(.horizontal, 6)
                    Capsule().fill(Theme.accent).frame(width: max(0, x), height: 4).padding(.leading, 0)
                    ForEach(0..<steps.count, id: \.self) { step in
                        Circle()
                            .fill(step <= index ? Theme.accent : Theme.textTertiary.opacity(0.6))
                            .frame(width: 4, height: 4)
                            .position(x: 6 + span * CGFloat(step) / CGFloat(count), y: geometry.size.height / 2)
                    }
                    Circle()
                        .fill(Theme.textPrimary)
                        .overlay(Circle().strokeBorder(Theme.accent, lineWidth: 2))
                        .frame(width: hovering || focused ? 14 : 12, height: hovering || focused ? 14 : 12)
                        .shadow(color: .black.opacity(0.3), radius: 2, y: 1)
                        .position(x: x, y: geometry.size.height / 2)
                        .animation(.easeOut(duration: 0.12), value: index)
                }
                .contentShape(Rectangle())
                .gesture(DragGesture(minimumDistance: 0).onChanged { drag in
                    let fraction = min(1, max(0, (drag.location.x - 6) / max(span, 1)))
                    let step = Int((fraction * CGFloat(count)).rounded())
                    if step != index { index = step }
                })
            }
            .frame(width: width, height: 18)
            .onHover { hovering = $0 }
            Text(steps[min(index, steps.count - 1)])
                .font(Theme.uiFont)
                .foregroundStyle(Theme.textPrimary)
                .frame(minWidth: 52, alignment: .leading)
        }
        .padding(.horizontal, 9)
        .frame(height: 24)
        .background(hovering ? Theme.hover : Theme.card)
        .overlay(RoundedRectangle(cornerRadius: Theme.rowRadius + 1)
            .strokeBorder(focused ? Theme.accent.opacity(0.6) : Theme.border, lineWidth: 1))
        .clipShape(RoundedRectangle(cornerRadius: Theme.rowRadius + 1))
        .focusable()
        .focusEffectDisabled()
        .focused($focused)
        .onKeyPress(.leftArrow) { index = max(0, index - 1); return .handled }
        .onKeyPress(.rightArrow) { index = min(steps.count - 1, index + 1); return .handled }
        .accessibilityElement()
        .accessibilityLabel(label)
        .accessibilityValue(steps[min(index, steps.count - 1)])
        .accessibilityAdjustableAction { direction in
            index = direction == .increment ? min(steps.count - 1, index + 1) : max(0, index - 1)
        }
    }
}
