import SwiftUI

/// App-wide progress and confirmation toasts for lasting actions.
@MainActor
final class ToastCenter: ObservableObject {
    static let shared = ToastCenter()

    enum Style: Equatable { case progress, success, failure, info }

    /// A button on a toast, such as Reopen on a closed tab's.
    struct Action: Equatable {
        let title: String
        let perform: @MainActor () -> Void

        static func == (lhs: Action, rhs: Action) -> Bool { lhs.title == rhs.title }
    }

    struct Toast: Identifiable, Equatable {
        let id = UUID()
        var style: Style
        var title: String
        var detail: String?
        var action: Action?
        /// Progress toasts stay hidden until the work runs past this moment,
        /// so instant socket calls only show their confirmation.
        var visibleAfter: Date = .distantPast
    }

    /// Opaque reference to a toast that will be updated when work finishes.
    struct Handle { fileprivate let id: UUID }

    @Published private(set) var toasts: [Toast] = []
    /// When each finished toast goes away; a toast under the pointer is held.
    private var deadlines: [UUID: Date] = [:]
    private var held: [UUID: TimeInterval] = [:]

    static let progressDelay: TimeInterval = 0.2
    static let maxVisible = 4

    /// Shows a progress toast (after a short delay) and returns a handle to finish it.
    @discardableResult
    func progress(_ title: String, detail: String? = nil) -> Handle {
        let toast = Toast(style: .progress, title: title, detail: detail,
                          visibleAfter: Date().addingTimeInterval(Self.progressDelay))
        toasts.append(toast)
        DispatchQueue.main.asyncAfter(deadline: .now() + Self.progressDelay + 0.01) { [weak self] in
            self?.objectWillChange.send()
        }
        trim()
        return Handle(id: toast.id)
    }

    func succeed(_ handle: Handle?, _ title: String, detail: String? = nil) {
        finish(handle, style: .success, title: title, detail: detail, after: 3.5)
    }

    func fail(_ handle: Handle?, _ title: String, detail: String? = nil, action: Action? = nil) {
        finish(handle, style: .failure, title: title, detail: detail, after: 8, action: action)
    }

    func info(_ title: String, detail: String? = nil, after seconds: TimeInterval = 3.5, action: Action? = nil) {
        finish(nil, style: .info, title: title, detail: detail, after: seconds, action: action)
    }

    /// Updates a running toast's text without finishing it.
    func update(_ handle: Handle, title: String, detail: String? = nil) {
        guard let index = toasts.firstIndex(where: { $0.id == handle.id }) else { return }
        toasts[index].title = title
        toasts[index].detail = detail
    }

    func dismiss(handleId handle: Handle) {
        dismiss(handle.id)
    }

    func dismiss(_ id: UUID) {
        toasts.removeAll { $0.id == id }
        deadlines[id] = nil
        held[id] = nil
    }

    /// The pointer is on a toast: it stays until the pointer leaves.
    func hold(_ id: UUID) {
        guard let deadline = deadlines[id] else { return }
        held[id] = max(2, deadline.timeIntervalSinceNow)
        deadlines[id] = nil
    }

    /// The pointer left: the toast gets what time it had left, at least 2s.
    func release(_ id: UUID) {
        guard let remaining = held.removeValue(forKey: id) else { return }
        schedule(id, after: remaining)
    }

    private func schedule(_ id: UUID, after seconds: TimeInterval) {
        let deadline = Date().addingTimeInterval(seconds)
        deadlines[id] = deadline
        DispatchQueue.main.asyncAfter(deadline: .now() + seconds) { [weak self] in
            // A newer deadline, or a hold, supersedes this one.
            guard let self, self.deadlines[id] == deadline else { return }
            self.dismiss(id)
        }
    }

    var visibleToasts: [Toast] {
        let now = Date()
        return Array(toasts.filter { $0.visibleAfter <= now }.suffix(Self.maxVisible))
    }

    private func finish(_ handle: Handle?, style: Style, title: String, detail: String?, after seconds: TimeInterval,
                        action: Action? = nil) {
        let id: UUID
        if let handle, let index = toasts.firstIndex(where: { $0.id == handle.id }) {
            toasts[index].style = style
            toasts[index].title = title
            toasts[index].detail = detail
            toasts[index].visibleAfter = .distantPast
            id = handle.id
        } else {
            let toast = Toast(style: style, title: title, detail: detail, action: action)
            toasts.append(toast)
            id = toast.id
        }
        trim()
        schedule(id, after: seconds)
        // A toast is easy to miss without sight: say it to VoiceOver too.
        if NSApp?.isActive == true {
            AttentionRouter.announce([title, detail].compactMap { $0 }.filter { !$0.isEmpty }.joined(separator: ". "))
        }
    }

    private func trim() {
        let finished = toasts.filter { $0.style != .progress }
        if finished.count > 8, let oldest = finished.first {
            dismiss(oldest.id)
        }
    }
}

/// Toast stack, bottom-right: flat glass cards that slide up, pause while
/// the pointer is on them, and show their close and copy buttons on hover.
struct ToastStack: View {
    @ObservedObject var center: ToastCenter
    @ObservedObject private var motion = MotionPreferences.shared
    @StateObject private var host = HostWindow()

    var body: some View {
        VStack(alignment: .trailing, spacing: 8) {
            // Toasts follow you: they show in whichever Octet window is in front.
            ForEach(host.isFront ? center.visibleToasts : []) { toast in
                ToastCard(toast: toast, perform: { action in
                    center.dismiss(toast.id)
                    action.perform()
                }, dismiss: { center.dismiss(toast.id) },
                   hover: { inside in
                    if inside { center.hold(toast.id) } else { center.release(toast.id) }
                })
                    .frame(width: ToastCard.width, alignment: .leading)
                    .fixedSize(horizontal: false, vertical: true)
                    .transition(motion.animates(.toasts)
                        ? .move(edge: .bottom).combined(with: .opacity).combined(with: .scale(scale: 0.96, anchor: .bottomTrailing))
                        : .identity)
            }
        }
        .fixedSize(horizontal: true, vertical: true)
        .animation(motion.animation(.toasts, .smooth(duration: 0.24)), value: center.visibleToasts)
        .padding(16)
        .background(HostWindowReader(host: host))
    }
}

private struct ToastCard: View {
    static let width: CGFloat = 348

    let toast: ToastCenter.Toast
    let perform: (ToastCenter.Action) -> Void
    let dismiss: () -> Void
    let hover: (Bool) -> Void
    @State private var hovered = false
    @State private var copied = false

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            icon.frame(width: 16, height: 16).padding(.top, 1)
            VStack(alignment: .leading, spacing: 3) {
                Text(toast.title)
                    .font(Theme.uiFontMedium)
                    .foregroundStyle(Theme.textPrimary)
                    .lineLimit(2)
                if let detail = toast.detail, !detail.isEmpty {
                    Text(detail)
                        .font(Theme.interfaceFont(12))
                        .foregroundStyle(Theme.textSecondary)
                        .lineLimit(4)
                        .textSelection(.enabled)
                }
                if let action = toast.action {
                    OctetButton(title: action.title, kind: .secondary, compact: true) { perform(action) }
                        .padding(.top, 4)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .fixedSize(horizontal: false, vertical: true)
            // Room for the buttons, which float over the corner so they
            // never set the card's height.
            .padding(.trailing, toast.style == .progress ? 0 : (copyable ? 44 : 22))
        }
        // Out of the way until the pointer is on the toast; always there
        // for a failure, whose details are worth copying.
        .overlay(alignment: .topTrailing) {
            if toast.style != .progress {
                HStack(spacing: 0) {
                    if copyable {
                        OctetIconButton(icon: copied ? "checkmark" : "doc.on.doc", help: "Copy details", compact: true) {
                            NSPasteboard.general.clearContents()
                            NSPasteboard.general.setString("\(toast.title)\n\(toast.detail ?? "")", forType: .string)
                            copied = true
                        }
                    }
                    OctetIconButton(icon: "xmark", help: "Dismiss", compact: true, action: dismiss)
                        .hoverReveal(hovered || toast.style == .failure)
                }
                .animation(.easeOut(duration: 0.12), value: hovered)
                .offset(x: 6, y: -5)
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 12)
        .octetGlass(cornerRadius: Theme.popoverRadius, fill: Theme.card)
        .overlay(RoundedRectangle(cornerRadius: Theme.popoverRadius, style: .continuous)
            .strokeBorder(toast.style == .failure ? accent.opacity(0.4) : .clear, lineWidth: 1))
        .onHover { inside in
            hovered = inside
            hover(inside)
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel([toast.title, toast.detail].compactMap { $0 }.joined(separator: ". "))
    }

    private var copyable: Bool {
        toast.style == .failure && !(toast.detail ?? "").isEmpty
    }

    private var accent: Color {
        switch toast.style {
        case .progress, .info: return Theme.accent
        case .success: return Theme.success
        case .failure: return Theme.danger
        }
    }

    @ViewBuilder
    private var icon: some View {
        switch toast.style {
        case .progress:
            LoadingLine(width: 16)
        case .success:
            OctetIcon("checkmark.circle.fill", size: 16).foregroundStyle(accent)
        case .failure:
            OctetIcon("exclamationmark.triangle.fill", size: 16).foregroundStyle(accent)
        case .info:
            OctetIcon("info.circle.fill", size: 16).foregroundStyle(accent)
        }
    }
}
