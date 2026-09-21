import AppKit
import SwiftUI

/// Octet's own confirmation dialog, in place of the system alert: it follows
/// the theme, animates with the rest of the chrome, and never steals the
/// window's focus ring.
@MainActor
final class ConfirmCenter: ObservableObject {
    struct Request: Identifiable {
        let id = UUID()
        var title: String
        var message: String = ""
        /// Extra lines, each shown as its own row (workspaces to close, …).
        var items: [String] = []
        /// Long monospace output to read before answering (an install
        /// preview, a plugin's log). Scrolls rather than truncating.
        var detail: String = ""
        var confirmTitle = "OK"
        /// Empty means the dialog is informational: one button, no cancel.
        var cancelTitle = "Cancel"
        var destructive = false
        /// Shown as a checkbox when set; the answer comes back on confirm.
        var suppressTitle: String?
        var onConfirm: (_ suppress: Bool) -> Void
        var onCancel: () -> Void = {}
        /// The window that was in front when this was asked; it draws the
        /// dialog. nil (or closed since) falls back to the terminal window.
        weak var window: NSWindow? = NSApp.keyWindow
    }

    static let shared = ConfirmCenter()

    @Published private(set) var request: Request?
    @Published var suppress = false

    /// Queues a confirmation; a second one waits until the first is answered.
    private var pending: [Request] = []

    func ask(_ request: Request) {
        if self.request == nil {
            suppress = false
            self.request = request
        } else {
            pending.append(request)
        }
    }

    /// Convenience for the common shape.
    func ask(
        title: String,
        message: String = "",
        items: [String] = [],
        detail: String = "",
        confirmTitle: String = "OK",
        cancelTitle: String = "Cancel",
        destructive: Bool = false,
        suppressTitle: String? = nil,
        onConfirm: @escaping (Bool) -> Void
    ) {
        ask(Request(title: title, message: message, items: items, detail: detail, confirmTitle: confirmTitle,
                    cancelTitle: cancelTitle, destructive: destructive, suppressTitle: suppressTitle,
                    onConfirm: onConfirm))
    }

    /// A read-only dialog, for output there is nothing to decide about.
    func show(title: String, message: String = "", detail: String = "") {
        ask(Request(title: title, message: message, detail: detail, confirmTitle: "Done",
                    cancelTitle: "", onConfirm: { _ in }))
    }

    func confirm() {
        let answered = request
        let suppressed = suppress
        advance()
        answered?.onConfirm(suppressed)
    }

    func cancel() {
        let answered = request
        advance()
        answered?.onCancel()
    }

    private func advance() {
        suppress = false
        request = pending.isEmpty ? nil : pending.removeFirst()
    }
}

struct ConfirmDialog: View {
    @ObservedObject var center: ConfirmCenter
    @ObservedObject private var motion = MotionPreferences.shared
    @StateObject private var host = HostWindow()

    var body: some View {
        ZStack {
            if let request = center.request, host.owns(request.window) {
                Color.black.opacity(0.35)
                    .ignoresSafeArea()
                    .onTapGesture { center.cancel() }
                card(request)
                    .transition(motion.animates(.palette)
                        ? .opacity.combined(with: .scale(scale: 0.96))
                        : .identity)
            }
        }
        .animation(motion.animation(.palette, .smooth(duration: 0.16)), value: center.request?.id)
        .background(HostWindowReader(host: host))
    }

    private func card(_ request: ConfirmCenter.Request) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(request.title)
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(Theme.textPrimary)
            if !request.message.isEmpty {
                Text(request.message)
                    .font(Theme.uiFont)
                    .foregroundStyle(Theme.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            if !request.items.isEmpty {
                VStack(alignment: .leading, spacing: 2) {
                    ForEach(request.items.prefix(8), id: \.self) { item in
                        Text(item)
                            .font(Theme.captionFont)
                            .foregroundStyle(Theme.textTertiary)
                            .lineLimit(1)
                            .truncationMode(.middle)
                    }
                    if request.items.count > 8 {
                        Text("and \(request.items.count - 8) more")
                            .font(Theme.captionFont)
                            .foregroundStyle(Theme.textTertiary)
                    }
                }
                .padding(8)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(RoundedRectangle(cornerRadius: 5).fill(Theme.hover))
            }
            if !request.detail.isEmpty {
                ScrollView {
                    Text(request.detail)
                        .font(Theme.monoFont)
                        .foregroundStyle(Theme.textSecondary)
                        .textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(8)
                }
                .frame(maxHeight: 240)
                .background(RoundedRectangle(cornerRadius: 5).fill(Theme.terminalBackground))
                .overlay(RoundedRectangle(cornerRadius: 5).strokeBorder(Theme.border, lineWidth: 1))
            }
            if let suppressTitle = request.suppressTitle {
                Toggle(suppressTitle, isOn: $center.suppress)
                    .toggleStyle(.checkbox)
                    .font(Theme.uiFont)
                    .foregroundStyle(Theme.textSecondary)
            }
            HStack(spacing: 8) {
                Spacer()
                if !request.cancelTitle.isEmpty {
                    DialogButton(title: request.cancelTitle, kind: .secondary) { center.cancel() }
                        .keyboardShortcut(.cancelAction)
                }
                DialogButton(title: request.confirmTitle, kind: request.destructive ? .destructive : .primary) {
                    center.confirm()
                }
                .keyboardShortcut(.defaultAction)
            }
            .padding(.top, 2)
        }
        .padding(16)
        .frame(width: request.detail.isEmpty ? 380 : 560)
        .background(Theme.card)
        .clipShape(RoundedRectangle(cornerRadius: 10))
        .overlay(RoundedRectangle(cornerRadius: 10).strokeBorder(Theme.border, lineWidth: 1))
        .shadow(color: .black.opacity(0.45), radius: 30, y: 12)
    }
}

private struct DialogButton: View {
    enum Kind { case primary, secondary, destructive }

    let title: String
    let kind: Kind
    let action: () -> Void
    @State private var hovered = false

    var body: some View {
        Button(action: action) {
            Text(title)
                .font(Theme.uiFontMedium)
                .foregroundStyle(foreground)
                .padding(.horizontal, 14)
                .padding(.vertical, 6)
                .background {
                    RoundedRectangle(cornerRadius: 6).fill(background)
                    RoundedRectangle(cornerRadius: 6).strokeBorder(Theme.border, lineWidth: kind == .secondary ? 1 : 0)
                }
        }
        .buttonStyle(.plain)
        .onHover { hovered = $0 }
    }

    private var foreground: Color {
        switch kind {
        case .secondary: Theme.textSecondary
        case .primary: Theme.onAccent
        case .destructive: .white
        }
    }

    private var background: Color {
        switch kind {
        case .primary: Theme.accent.opacity(hovered ? 0.85 : 1)
        // Dark enough for white text on light and dark themes alike.
        case .destructive: Color(hex: "c62a2f").opacity(hovered ? 0.85 : 1)
        case .secondary: hovered ? Theme.hover : Color.clear
        }
    }
}
