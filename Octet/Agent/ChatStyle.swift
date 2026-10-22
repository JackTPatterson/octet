import SwiftUI

/// The conversation view's look, after T3 Code's chat (pingdotgg/t3code,
/// apps/web): its own surfaces, type scale and metrics, kept here so the
/// rest of Octet's chrome is untouched. Dark themes get T3 Code's dark
/// surfaces outright; light themes keep Octet's palette, which already
/// follows T3 Code's light one closely.
enum ChatStyle {
    // MARK: Surfaces
    // Resolved from T3 Code's dark tokens (apps/web/src/index.css, .dark).

    /// The page behind the transcript: neutral-950.
    static var page: Color { Theme.isLight ? Theme.terminalBackground : Color(hex: "0A0A0A") }
    /// Raised surfaces (the composer): the page with 3% white.
    static var card: Color { Theme.isLight ? Theme.card : Color(hex: "111111") }
    /// Your messages (bg-message): white at 4%.
    static var bubble: Color { Theme.isLight ? Theme.card : Color(hex: "141414") }
    /// The changed-files card and code blocks: white at 1.6–2.6%.
    static var inset: Color { Theme.isLight ? Theme.card : Color(hex: "0E0E0E") }
    static var codeBlock: Color { Theme.isLight ? Theme.card : Color(hex: "101010") }
    /// A control under the pointer (accent): white at 4%.
    static var hover: Color { Theme.isLight ? Theme.hover : Color(hex: "141414") }
    /// Hairlines: white at 6%; inputs 8%; the composer's outline 5%.
    static var border: Color { Theme.isLight ? Theme.border : Color(hex: "191919") }
    static var inputBorder: Color { Theme.isLight ? Theme.border : Color(hex: "1E1E1E") }
    static var composerOutline: Color { Theme.isLight ? Theme.border : Color(hex: "161616") }
    /// The rule under "Worked for…": border at 60%.
    static var rowRule: Color { Theme.isLight ? Theme.divider : Color(hex: "141414") }

    /// Foreground (neutral-100), the assistant's prose at 80% of it, and
    /// muted-foreground for labels, icons and metadata.
    static var text: Color { Theme.isLight ? Theme.textPrimary : Color(hex: "F5F5F5") }
    static var prose: Color { Theme.isLight ? Theme.textPrimary : Color(hex: "C6C6C6") }
    static var mutedText: Color { Theme.isLight ? Theme.textTertiary : Color(hex: "818181") }
    static var secondaryText: Color { Theme.isLight ? Theme.textSecondary : Color(hex: "818181") }
    /// Icons in the work log: muted at 70%.
    static var faintIcon: Color { Theme.isLight ? Theme.textTertiary : Color(hex: "5D5D5D") }
    static var placeholder: Color { Theme.isLight ? Theme.textTertiary : Color(hex: "636363") }

    /// The accent: white, not T3 Code's blue (near-black on a light theme,
    /// where white would vanish), and what's drawn on it.
    static var primary: Color { Theme.isLight ? Theme.textPrimary : Color(hex: "F5F5F5") }
    static var primaryHover: Color { Theme.isLight ? Theme.textPrimary.opacity(0.85) : Color(hex: "DADADA") }
    static var onPrimary: Color { Theme.isLight ? Color.white : Color(hex: "0A0A0A") }
    static var link: Color { Color(hex: Theme.isLight ? "2563EB" : "51A2FF") }
    static var added: Color { Color(hex: Theme.isLight ? "059669" : "00BC7D") }
    static var removed: Color { Color(hex: Theme.isLight ? "DC2626" : "FB414A") }
    static var warning: Color { Color(hex: "FE9A00") }

    // MARK: Type

    /// Chat text: text-sm, leading-relaxed (22.75pt lines).
    static var body: Font { Theme.interfaceFont(14) }
    static var bodyMedium: Font { Theme.interfaceFont(14, weight: .medium) }
    static let bodyLineSpacing: CGFloat = 6
    /// Metadata and small controls, text-xs.
    static var meta: Font { Theme.interfaceFont(12) }
    static var metaMedium: Font { Theme.interfaceFont(12, weight: .medium) }
    /// The composer's prompt (--font-size-prompt).
    static var prompt: Font { Theme.interfaceFont(14) }

    // MARK: Metrics

    /// --chat-content-max-width (46rem), the column at ordinary widths.
    static let columnWidth: CGFloat = 736
    /// T3 Code's "wide" content width (72rem), what a large monitor grows
    /// the column to.
    static let wideColumnWidth: CGFloat = 1152

    /// The column for a conversation `available` points wide: 736 until
    /// the window has room to spare, then 60% of it, up to 1152, so an
    /// ultrawide isn't a thin strip in a sea of black.
    static func columnWidth(for available: CGFloat) -> CGFloat {
        min(wideColumnWidth, max(columnWidth, (available * 0.6).rounded()))
    }
    /// The timeline's and composer's side padding at sm and up (3rem).
    static let gutter: CGFloat = 48
    /// The header's own padding (px-5).
    static let headerPadding: CGFloat = 20
    /// --workspace-topbar-height.
    static let headerHeight: CGFloat = 52
    /// rounded-2xl and rounded-3xl, as T3 Code redefines them.
    static let bubbleRadius: CGFloat = 18
    static let composerRadius: CGFloat = 22
    /// rounded-lg: cards and code blocks.
    static let cardRadius: CGFloat = 10
    /// --control-radius.
    static let controlRadius: CGFloat = 8
    static let sendSize: CGFloat = 32
    /// A work-log line, and the column its icon sits in.
    static let workRowHeight: CGFloat = 24
    static let workIconColumn: CGFloat = 24
}

/// Keeps a view to the chat column, centred, with the page gutters. Every
/// part of the conversation measures the same full width, so the
/// transcript, banners and composer stay lined up as the column grows.
struct ChatColumn: ViewModifier {
    @State private var available: CGFloat = 0

    func body(content: Content) -> some View {
        content
            .frame(maxWidth: ChatStyle.columnWidth(for: available))
            .padding(.horizontal, ChatStyle.gutter)
            .frame(maxWidth: .infinity)
            .onGeometryChange(for: CGFloat.self) { $0.size.width } action: { available = $0 }
    }
}

extension View {
    func chatColumn() -> some View { modifier(ChatColumn()) }
}

/// T3 Code's outline button (variant="outline" size="xs"): a hairline,
/// a lit fill under the pointer, used for Open diff and the like.
struct ChatOutlineButton: View {
    let title: String
    var icon: String?
    let action: () -> Void
    @State private var hovered = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: 5) {
                if let icon { OctetIcon(icon, size: 12) }
                Text(title).font(ChatStyle.metaMedium)
            }
            .foregroundStyle(ChatStyle.text)
            .padding(.horizontal, 9)
            .frame(height: 26)
            .background(RoundedRectangle(cornerRadius: 7, style: .continuous)
                .fill(hovered ? ChatStyle.hover : Color.clear))
            .overlay(RoundedRectangle(cornerRadius: 7, style: .continuous)
                .strokeBorder(ChatStyle.inputBorder, lineWidth: 1))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hovered = $0 }
    }
}

/// T3 Code's ComposerControl (size="sm"): no border or fill at rest, 28pt
/// tall, the accent fill and full-strength text under the pointer or open.
struct ChatComposerControl: ViewModifier {
    var active: Bool

    func body(content: Content) -> some View {
        content
            .font(ChatStyle.bodyMedium)
            .padding(.horizontal, 10)
            .frame(height: 28)
            .background(RoundedRectangle(cornerRadius: ChatStyle.controlRadius, style: .continuous)
                .fill(active ? ChatStyle.hover : Color.clear))
            .contentShape(RoundedRectangle(cornerRadius: ChatStyle.controlRadius, style: .continuous))
    }
}

extension View {
    func chatComposerControl(active: Bool) -> some View { modifier(ChatComposerControl(active: active)) }
}

extension String {
    /// "auto mode on" as a control's label: "Auto mode on".
    var capitalizedFirst: String { prefix(1).uppercased() + dropFirst() }
}

/// T3 Code's ghost icon button (size="icon-sm"): 28pt square, a 16pt icon
/// in the muted colour, the accent fill under the pointer.
struct ChatIconButton: View {
    let icon: String
    let help: String
    let action: () -> Void
    @State private var hovered = false

    var body: some View {
        Button(action: action) {
            OctetIcon(icon, size: 16)
                .foregroundStyle(hovered ? ChatStyle.text : ChatStyle.mutedText)
                .frame(width: 28, height: 28)
                .background(RoundedRectangle(cornerRadius: ChatStyle.controlRadius, style: .continuous)
                    .fill(hovered ? ChatStyle.hover : Color.clear))
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hovered = $0 }
        .help(help)
        .accessibilityLabel(help)
    }
}

/// A line of T3 Code's work log, which opens to its detail: a 16pt icon in
/// a 24pt column, the label in the muted colour, and a small chevron at the
/// end that turns as it opens. Its detail sits under the label, 28pt in.
struct WorkLogDisclosure<Trailing: View, Content: View>: View {
    let title: String
    var subtitle: String = ""
    /// Commands keep their monospaced, highlighted look; paths and the
    /// rest read as words.
    var subtitleIsCode = false
    var tint: Color = ChatStyle.secondaryText
    var icon: String?
    var logo: LanguageLogo?
    var highlightsShell = false
    @ViewBuilder var trailing: () -> Trailing
    @ViewBuilder var content: () -> Content
    @State private var open: Bool
    @State private var hovered = false
    @Environment(\.transcriptFindMarks) private var marks

    init(title: String, subtitle: String = "", subtitleIsCode: Bool = false, tint: Color = ChatStyle.secondaryText,
         icon: String? = nil, logo: LanguageLogo? = nil, highlightsShell: Bool = false, initiallyOpen: Bool = false,
         @ViewBuilder trailing: @escaping () -> Trailing = { EmptyView() },
         @ViewBuilder content: @escaping () -> Content) {
        self.title = title
        self.subtitle = subtitle
        self.subtitleIsCode = subtitleIsCode
        self.tint = tint
        self.icon = icon
        self.logo = logo
        self.highlightsShell = highlightsShell
        _open = State(initialValue: initiallyOpen)
        self.trailing = trailing
        self.content = content
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            Button { withAnimation(.easeOut(duration: 0.2)) { open.toggle() } } label: {
                HStack(spacing: 6) {
                    OctetIcon(icon ?? "tool.other", size: 16)
                        .foregroundStyle(tint == ChatStyle.secondaryText ? ChatStyle.faintIcon : tint)
                        .frame(width: ChatStyle.workIconColumn)
                    Text(title).font(ChatStyle.body).foregroundStyle(tint)
                    if let logo { logo }
                    if !subtitle.isEmpty {
                        if highlightsShell {
                            WorkLogShellText(subtitle)
                        } else {
                            FoundText(subtitle, field: TranscriptFind.toolSummary)
                                .font(subtitleIsCode ? Theme.Text.mono(12.5) : ChatStyle.body)
                                .foregroundStyle(ChatStyle.secondaryText)
                                .lineLimit(1)
                                .truncationMode(.middle)
                        }
                    }
                    Spacer(minLength: 4)
                    trailing()
                    OctetIcon("chevron.right", size: 12)
                        .foregroundStyle(ChatStyle.faintIcon)
                        .rotationEffect(.degrees(open ? 90 : 0))
                        .frame(width: 16, height: 16)
                }
                .frame(minHeight: ChatStyle.workRowHeight)
                .padding(2)
                .background(RoundedRectangle(cornerRadius: ChatStyle.controlRadius, style: .continuous)
                    .fill(hovered ? ChatStyle.hover : .clear))
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .onHover { hovered = $0 }
            .accessibilityLabel("\(title) \(subtitle)")
            .accessibilityValue(open ? "Expanded" : "Collapsed")
            if open {
                content()
                    .padding(.leading, 28)
                    .padding(.bottom, 6)
            }
        }
        // The current match is in what this hides: show it.
        .onChange(of: revealed) { _, now in if now { open = true } }
        .onAppear { if revealed { open = true } }
    }

    private var revealed: Bool {
        guard let field = marks?.current?.field else { return false }
        return field != TranscriptFind.toolSummary
    }
}

/// A shell command in a work-log line: monospaced and muted, one line.
struct WorkLogShellText: View {
    let source: String
    init(_ source: String) { self.source = source }

    var body: some View {
        Text(source)
            .font(Theme.Text.mono(12.5))
            .foregroundStyle(ChatStyle.secondaryText)
            .lineLimit(1)
            .truncationMode(.middle)
    }
}

/// What sits on top of the composer (an approval, a question, the queue),
/// after T3 Code's ComposerBanner: narrower than the composer by 22pt a
/// side, rounded 18 on top, tucked under the composer's edge, its outline
/// and wash in the banner's tone.
struct ChatBanner<Content: View>: View {
    enum Tone { case neutral, warning, error }
    var tone: Tone = .neutral
    @ViewBuilder let content: () -> Content

    /// How far the composer's card covers the banner's foot, with the 8pt
    /// the composer keeps above its card.
    static var overlap: CGFloat { 17 + 8 }

    var body: some View {
        let shape = UnevenRoundedRectangle(topLeadingRadius: 18, bottomLeadingRadius: 0,
                                           bottomTrailingRadius: 0, topTrailingRadius: 18, style: .continuous)
        content()
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.bottom, Self.overlap)
            .background {
                ZStack {
                    shape.fill(ChatStyle.card)
                    if let tint { shape.fill(tint.opacity(0.08)) }
                }
            }
            .clipShape(shape)
            .overlay(shape.strokeBorder(tint.map { $0.opacity(tone == .error ? 0.32 : 0.28) } ?? ChatStyle.composerOutline,
                                        lineWidth: 1))
            .padding(.horizontal, 22)
            // Whatever comes next (another banner, the composer) covers the foot.
            .padding(.bottom, -Self.overlap)
    }

    private var tint: Color? {
        switch tone {
        case .neutral: nil
        case .warning: ChatStyle.warning
        case .error: ChatStyle.removed
        }
    }
}

/// T3 Code's small buttons (size="xs"): 24pt tall, 12pt medium words.
/// Primary in the accent with a lit top edge, outline on the input fill,
/// ghost in the muted colour.
struct ChatButton: View {
    enum Kind { case primary, outline, ghost }
    let title: String
    var icon: String?
    var kind: Kind = .outline
    let action: () -> Void
    @State private var hovered = false
    @Environment(\.isEnabled) private var enabled

    var body: some View {
        Button(action: action) {
            HStack(spacing: 4) {
                if let icon { OctetIcon(icon, size: 12) }
                Text(title).font(ChatStyle.metaMedium)
            }
            .foregroundStyle(foreground)
            .padding(.horizontal, 8)
            .frame(height: 24)
            .background(RoundedRectangle(cornerRadius: ChatStyle.controlRadius, style: .continuous).fill(fill))
            .overlay {
                if kind != .ghost {
                    RoundedRectangle(cornerRadius: ChatStyle.controlRadius, style: .continuous)
                        .strokeBorder(kind == .primary ? ChatStyle.primary : ChatStyle.inputBorder, lineWidth: 1)
                }
            }
            .overlay(alignment: .top) {
                if kind == .primary {
                    Capsule().fill(Color.white.opacity(0.16)).frame(height: 1).padding(.horizontal, 6).padding(.top, 1)
                }
            }
            .shadow(color: kind == .primary ? ChatStyle.primary.opacity(0.24) : .clear, radius: 1, y: 1)
            .opacity(enabled ? 1 : 0.64)
            .contentShape(Rectangle())
        }
        .buttonStyle(OctetPressStyle())
        .onHover { hovered = $0 }
    }

    private var foreground: Color {
        switch kind {
        case .primary: ChatStyle.onPrimary
        case .outline: ChatStyle.text
        case .ghost: hovered ? ChatStyle.text : ChatStyle.mutedText
        }
    }

    private var fill: Color {
        switch kind {
        case .primary: hovered ? ChatStyle.primaryHover : ChatStyle.primary
        case .outline: Theme.isLight ? (hovered ? Theme.hover : Theme.card) : Color(hex: hovered ? "171717" : "101010")
        case .ghost: hovered ? ChatStyle.hover : .clear
        }
    }
}

/// T3 Code's composer command menu (`/`, `@`): rows rounded 10, the
/// highlighted one on the accent fill, which slides between rows; at most
/// 288pt tall before it scrolls.
struct ChatCommandList<Item: Identifiable, Row: View>: View where Item.ID: Hashable {
    let items: [Item]
    let highlighted: Int
    let highlight: (Int) -> Void
    let choose: (Item) -> Void
    @ViewBuilder let row: (Item, Bool) -> Row

    @ObservedObject private var motion = MotionPreferences.shared
    @Namespace private var selection

    var body: some View {
        ScrollViewReader { proxy in
            ScrollView {
                VStack(alignment: .leading, spacing: 0) {
                    ForEach(Array(items.enumerated()), id: \.element.id) { index, item in
                        row(item, index == highlighted)
                            .padding(.horizontal, 8)
                            .frame(maxWidth: .infinity, minHeight: 32, alignment: .leading)
                            .background {
                                if index == highlighted {
                                    RoundedRectangle(cornerRadius: ChatStyle.cardRadius, style: .continuous)
                                        .fill(ChatStyle.hover)
                                        .matchedGeometryEffect(id: "highlight", in: selection)
                                }
                            }
                            .contentShape(Rectangle())
                            .id(item.id)
                            .onHover { hovering in
                                if hovering, index != highlighted { highlight(index) }
                            }
                            .onTapGesture { choose(item) }
                            .accessibilityElement(children: .combine)
                            .accessibilityAddTraits(index == highlighted ? [.isButton, .isSelected] : .isButton)
                            .accessibilityAction { choose(item) }
                    }
                }
                .padding(6)
            }
            .scrollIndicators(.never)
            .frame(maxHeight: 288)
            .fixedSize(horizontal: false, vertical: true)
            .onChange(of: highlighted) { _, index in
                guard items.indices.contains(index) else { return }
                proxy.scrollTo(items[index].id)
            }
        }
        .animation(motion.animation(.palette, .smooth(duration: 0.14)), value: highlighted)
    }
}

/// One row of the command menu: an optional 16pt icon, the label in 12pt
/// medium (never more than 45% of the row), then its description, muted.
struct ChatCommandRow<Icon: View, Label: View>: View {
    @ViewBuilder var icon: () -> Icon
    @ViewBuilder var label: () -> Label
    var description: String = ""
    var badge: String = ""
    /// The label's own width, measured, so it takes no more than it needs.
    @State private var labelWidth: CGFloat = 0

    var body: some View {
        GeometryReader { proxy in
            HStack(spacing: 8) {
                icon()
                styledLabel
                    .truncationMode(.tail)
                    .frame(width: min(labelWidth, proxy.size.width * 0.45), alignment: .leading)
                    .background {
                        styledLabel.fixedSize().hidden()
                            .onGeometryChange(for: CGFloat.self) { $0.size.width } action: { labelWidth = $0 }
                    }
                Text(description)
                    .font(ChatStyle.meta)
                    .foregroundStyle(ChatStyle.secondaryText)
                    .lineLimit(1)
                    .truncationMode(.tail)
                    .frame(maxWidth: .infinity, alignment: .leading)
                if !badge.isEmpty {
                    Text(badge)
                        .font(Theme.interfaceFont(11, weight: .medium))
                        .foregroundStyle(ChatStyle.secondaryText)
                        .padding(.horizontal, 6)
                        .frame(height: 18)
                        .background(RoundedRectangle(cornerRadius: 6, style: .continuous).fill(ChatStyle.bubble))
                }
            }
            .frame(maxHeight: .infinity)
        }
        .frame(height: 32)
    }

    private var styledLabel: some View {
        label()
            .font(ChatStyle.metaMedium)
            .foregroundStyle(ChatStyle.text)
            .lineLimit(1)
    }
}

/// T3 Code's popover (dropdown-glass): the raised surface over a blur,
/// rounded 10, a 10% foreground outline, a lit top edge and a deep, soft
/// shadow.
struct ChatPopover: ViewModifier {
    func body(content: Content) -> some View {
        let shape = RoundedRectangle(cornerRadius: ChatStyle.cardRadius, style: .continuous)
        content
            .background {
                ZStack {
                    shape.fill(.ultraThinMaterial)
                    shape.fill(ChatStyle.card.opacity(0.84))
                }
            }
            .clipShape(shape)
            .overlay(shape.strokeBorder(ChatStyle.text.opacity(0.1), lineWidth: 1))
            .overlay(alignment: .top) {
                Capsule().fill(Color.white.opacity(Theme.isLight ? 0 : 0.06)).frame(height: 1)
                    .padding(.horizontal, ChatStyle.cardRadius)
            }
            .shadow(color: .black.opacity(Theme.isLight ? 0.55 : 0.8), radius: 22, y: 18)
            .environment(\.colorScheme, Theme.colorScheme)
    }
}

extension View {
    func chatPopover() -> some View { modifier(ChatPopover()) }
}
