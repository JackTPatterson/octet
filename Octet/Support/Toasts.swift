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

    func fail(_ handle: Handle?, _ title: String, detail: String? = nil) {
        finish(handle, style: .failure, title: title, detail: detail, after: 8)
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
        DispatchQueue.main.asyncAfter(deadline: .now() + seconds) { [weak self] in
            self?.dismiss(id)
        }
    }

    private func trim() {
        let finished = toasts.filter { $0.style != .progress }
        if finished.count > 8, let oldest = finished.first {
            dismiss(oldest.id)
        }
    }
}

/// Toast stack, bottom-right, card styling.
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
                }) { center.dismiss(toast.id) }
                    .frame(width: ToastCard.width, alignment: .leading)
                    .fixedSize(horizontal: false, vertical: true)
                    .transition(motion.animates(.toasts) ? .move(edge: .trailing).combined(with: .opacity) : .identity)
            }
        }
        .fixedSize(horizontal: true, vertical: true)
        .animation(motion.animation(.toasts, .easeOut(duration: 0.18)), value: center.visibleToasts)
        .padding(16)
        .background(HostWindowReader(host: host))
    }
}

private struct ToastCard: View {
    static let width: CGFloat = 360

    let toast: ToastCenter.Toast
    let perform: (ToastCenter.Action) -> Void
    let dismiss: () -> Void

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            icon.frame(width: 16, height: 16)
            VStack(alignment: .leading, spacing: 2) {
                Text(toast.title)
                    .font(Theme.uiFontMedium)
                    .foregroundStyle(Theme.textPrimary)
                    .lineLimit(2)
                if let detail = toast.detail, !detail.isEmpty {
                    Text(detail)
                        .font(Theme.uiFont)
                        .foregroundStyle(Theme.textSecondary)
                        .lineLimit(4)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .fixedSize(horizontal: false, vertical: true)
            if let action = toast.action {
                Button(action.title) { perform(action) }
                    .font(Theme.uiFontMedium)
                    .buttonStyle(.plain)
                    .foregroundStyle(Theme.accent)
                    .padding(.horizontal, 8)
                    .frame(height: 22)
                    .background(Theme.accent.opacity(0.14))
                    .clipShape(RoundedRectangle(cornerRadius: 5))
            }
            if toast.style != .progress {
                Button(action: dismiss) {
                    OctetIcon("xmark", size: 16)
                }
                .buttonStyle(.plain)
                .foregroundStyle(Theme.textTertiary)
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
        .background(
            LinearGradient(
                stops: [
                    .init(color: accent.opacity(0.28), location: 0),
                    .init(color: accent.opacity(0), location: 0.5),
                ],
                startPoint: .leading,
                endPoint: .trailing
            )
        )
        .background(Theme.card)
        .overlay(RoundedRectangle(cornerRadius: 6).strokeBorder(Theme.border, lineWidth: 1))
        .clipShape(RoundedRectangle(cornerRadius: 6))
        .shadow(color: .black.opacity(0.4), radius: 12, y: 6)
    }

    private var accent: Color {
        switch toast.style {
        case .progress, .info: return Theme.accent
        case .success: return Color(hex: AgentStateColor.done)
        case .failure: return Color(hex: AgentStateColor.blocked)
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
