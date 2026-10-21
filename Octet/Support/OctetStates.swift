import AppKit
import SwiftUI

// One empty, error and loading state, and one modal shell, so every pane
// says "nothing here", "that failed" and "on its way" the same way, and
// every dialog dims, rounds and closes alike.

extension Theme {
    /// Text drawn on a danger fill: whichever of white and black reads
    /// better on the theme's red, so a pale red on a dark theme still
    /// carries a readable label.
    static var onDanger: Color {
        let red = palette.danger
        return ThemePalette.contrast("ffffff", red) >= ThemePalette.contrast("000000", red) ? .white : .black
    }
}

// MARK: - Empty state

/// A pane with nothing to show: a mark in a soft tile, a line saying so, a
/// line saying what to do, and sometimes the action that does it. `compact`
/// is for narrow side panels, where a tile would crowd the message.
struct OctetEmptyState<Action: View>: View {
    let icon: String
    let title: String
    var message: String?
    var compact = false
    /// Fill the space it's given and centre in it; off for lists that put
    /// the state at the top.
    var fills = true
    @ViewBuilder var action: () -> Action

    var body: some View {
        VStack(spacing: compact ? Theme.Space.sm : Theme.Space.md + 2) {
            if compact {
                OctetIcon(icon, size: 20).foregroundStyle(Theme.textTertiary).padding(.bottom, Theme.Space.xxs)
            } else {
                OctetIcon(icon, size: 18)
                    .foregroundStyle(Theme.textTertiary)
                    .frame(width: 40, height: 40)
                    .background(RoundedRectangle(cornerRadius: Theme.Radius.xl).fill(Theme.card))
                    .overlay(RoundedRectangle(cornerRadius: Theme.Radius.xl).strokeBorder(Theme.border, lineWidth: 1))
            }
            VStack(spacing: Theme.Space.xs) {
                Text(title)
                    .font(compact ? Theme.Text.bodyMedium : Theme.interfaceFont(13, weight: .medium))
                    .foregroundStyle(compact ? Theme.textSecondary : Theme.textPrimary)
                    .multilineTextAlignment(.center)
                if let message, !message.isEmpty {
                    Text(message)
                        .font(compact ? Theme.Text.caption : Theme.Text.body)
                        .foregroundStyle(Theme.textTertiary)
                        .multilineTextAlignment(.center)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            .accessibilityElement(children: .combine)
            action()
                .padding(.top, Theme.Space.xxs)
        }
        .frame(maxWidth: 320)
        .padding(Theme.Space.xxl)
        .frame(maxWidth: .infinity, maxHeight: fills ? .infinity : nil)
    }
}

extension OctetEmptyState where Action == EmptyView {
    init(icon: String, title: String, message: String? = nil, compact: Bool = false, fills: Bool = true) {
        self.init(icon: icon, title: title, message: message, compact: compact, fills: fills, action: { EmptyView() })
    }
}

extension OctetEmptyState where Action == OctetButton {
    /// The common shape: one titled button that does the obvious next thing.
    init(icon: String, title: String, message: String? = nil, compact: Bool = false, fills: Bool = true,
         actionTitle: String, actionIcon: String? = nil, perform: @escaping () -> Void) {
        self.init(icon: icon, title: title, message: message, compact: compact, fills: fills) {
            OctetButton(title: actionTitle, icon: actionIcon, kind: .secondary, compact: true, action: perform)
        }
    }
}

// MARK: - Error state

/// Something failed, after Orca's: what failed as the title, why in a
/// sentence, one action that moves on (Try Again, Open Settings), and the
/// raw output tucked behind "Copy details" for a bug report rather than
/// printed at the person.
struct OctetErrorState: View {
    let title: String
    let reason: String
    var actionTitle: String?
    var actionIcon: String? = "arrow.clockwise"
    var action: (() -> Void)?
    /// The underlying error or command output, copied on request.
    var details: String?
    var fills = true
    @State private var copied = false

    var body: some View {
        VStack(spacing: Theme.Space.md + 2) {
            OctetIcon("exclamationmark.triangle.fill", size: 18)
                .foregroundStyle(Theme.danger)
                .frame(width: 40, height: 40)
                .background(RoundedRectangle(cornerRadius: Theme.Radius.xl).fill(Theme.danger.opacity(0.1)))
                .overlay(RoundedRectangle(cornerRadius: Theme.Radius.xl).strokeBorder(Theme.danger.opacity(0.3), lineWidth: 1))
                .accessibilityHidden(true)
            VStack(spacing: Theme.Space.xs) {
                Text(title)
                    .font(Theme.interfaceFont(13, weight: .medium))
                    .foregroundStyle(Theme.textPrimary)
                    .multilineTextAlignment(.center)
                Text(reason)
                    .font(Theme.Text.body)
                    .foregroundStyle(Theme.textSecondary)
                    .multilineTextAlignment(.center)
                    .fixedSize(horizontal: false, vertical: true)
                    .textSelection(.enabled)
            }
            .accessibilityElement(children: .combine)
            HStack(spacing: Theme.Space.sm) {
                if let actionTitle, let action {
                    OctetButton(title: actionTitle, icon: actionIcon, kind: .primary, compact: true, action: action)
                }
                if let details, !details.isEmpty {
                    OctetButton(title: copied ? "Copied" : "Copy Details", icon: copied ? "check" : "doc.on.doc",
                                kind: .ghost, compact: true) { copy(details) }
                        .help("Copy the full error, for a bug report")
                }
            }
            .padding(.top, Theme.Space.xxs)
        }
        .frame(maxWidth: 340)
        .padding(Theme.Space.xxl)
        .frame(maxWidth: .infinity, maxHeight: fills ? .infinity : nil)
    }

    private func copy(_ text: String) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
        copied = true
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.4) { copied = false }
    }
}

// MARK: - Loading state

/// Something on its way with no shape to sketch yet: the loading line and
/// what's loading. Lists that know their shape use Skeleton rows instead.
struct OctetLoadingState: View {
    var title = "Loading…"
    var fills = true

    var body: some View {
        VStack(spacing: Theme.Space.md) {
            LoadingLine(width: 28)
            Text(title)
                .font(Theme.Text.caption)
                .foregroundStyle(Theme.textTertiary)
        }
        .padding(Theme.Space.xxl)
        .frame(maxWidth: .infinity, maxHeight: fills ? .infinity : nil)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(title)
    }
}

// MARK: - Modal shell

/// The frame every Octet dialog shares: the theme's scrim over the window,
/// the card scaling in on the palette's motion, Escape and a click on the
/// scrim closing it, and the card announced as modal. It draws only in the
/// window the dialog was raised from (see HostWindow), so a dialog asked
/// for from a sheet appears on the sheet, not behind it.
struct OctetModalShell<Card: View>: View {
    let isPresented: Bool
    /// The window the dialog was raised from; nil means the terminal window.
    var window: NSWindow?
    /// Changes when a different dialog replaces this one, so it animates.
    var identity: AnyHashable?
    /// Whether Escape and the scrim close it; off while it can't be left
    /// (an update running).
    var dismissible = true
    /// Off when the card's own buttons carry Escape (each phase's own
    /// cancel), so two controls don't claim the one key.
    var handlesEscape = true
    var overlayName: String?
    let onDismiss: () -> Void
    @ViewBuilder var card: () -> Card
    @ObservedObject private var motion = MotionPreferences.shared
    @StateObject private var host = HostWindow()

    var body: some View {
        ZStack {
            if isPresented, host.owns(window) {
                Theme.scrim
                    .ignoresSafeArea()
                    .onTapGesture { if dismissible { onDismiss() } }
                    .accessibilityHidden(true)
                card()
                    .environment(\.colorScheme, Theme.colorScheme)
                    .accessibilityAddTraits(.isModal)
                    .background {
                        // Escape reaches the dialog even when nothing in it
                        // has focus yet.
                        if handlesEscape {
                            Button("") { if dismissible { onDismiss() } }
                                .keyboardShortcut(.cancelAction)
                                .opacity(0)
                                .accessibilityHidden(true)
                        }
                    }
                    .transition(motion.animates(.palette)
                        ? .opacity.combined(with: .scale(scale: 0.96))
                        : .identity)
                    .onAppear { if let overlayName { DebugSnapshot.overlay(overlayName, true) } }
                    .onDisappear { if let overlayName { DebugSnapshot.overlay(overlayName, false) } }
            }
        }
        .animation(motion.animation(.palette, .smooth(duration: 0.16)), value: isPresented)
        .animation(motion.animation(.palette, .smooth(duration: 0.16)), value: identity)
        .background(HostWindowReader(host: host))
    }
}

extension View {
    /// A dialog card in the modal shell's glass: the sheet radius and the
    /// card fill.
    func octetModalCard(width: CGFloat, padding: CGFloat = Theme.Space.xl) -> some View {
        self
            .padding(padding)
            .frame(width: width)
            .octetGlass(cornerRadius: Theme.Radius.sheet, fill: Theme.card)
    }

    /// Lets Octet's own confirmations draw in a sheet. A SwiftUI sheet is its
    /// own window, and a confirmation asked for from it would otherwise wait
    /// unseen until the sheet closed.
    func hostsOctetDialogs() -> some View {
        overlay { ConfirmDialog(center: .shared) }
    }
}
