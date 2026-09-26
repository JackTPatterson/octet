import SwiftUI

/// Notices in the top-right of the window: an agent finished, or
/// it is waiting on you. Click one to jump to that pane.
@MainActor
final class AgentBannerCenter: ObservableObject {
    struct Banner: Identifiable, Equatable {
        let event: AgentEvent
        var id: String { event.id }
    }

    static let shared = AgentBannerCenter()
    static let lifetime: TimeInterval = 8
    static let maxVisible = 3

    @Published private(set) var banners: [Banner] = []

    func show(_ events: [AgentEvent]) {
        pushToPhone(events)
        guard SettingsStore.shared.values.notifications == .banner else { return }
        for event in events where !banners.contains(where: { $0.id == event.id }) {
            banners.append(Banner(event: event))
            DispatchQueue.main.asyncAfter(deadline: .now() + Self.lifetime) { [weak self] in
                self?.dismiss(event.id)
            }
        }
        if banners.count > Self.maxVisible {
            banners.removeFirst(banners.count - Self.maxVisible)
        }
    }

    /// Sends the notices to the phone topic in Settings, while you're away
    /// from Octet (it isn't in front).
    private func pushToPhone(_ events: [AgentEvent]) {
        let settings = SettingsStore.shared.values
        guard !settings.phoneTopic.isEmpty, !NSApp.isActive else { return }
        for event in events {
            let name = AgentBrand.forAgent(event.agent)?.displayName ?? event.agent ?? "An agent"
            guard let request = PhonePush.request(server: settings.phoneServer, topic: settings.phoneTopic,
                                                  event: event, agentName: name) else { continue }
            URLSession.shared.dataTask(with: request).resume()
        }
    }

    func dismiss(_ id: String) {
        banners.removeAll { $0.id == id }
    }

    func dismissAll() {
        banners.removeAll()
    }
}

struct AgentBannerStack: View {
    @ObservedObject var center: AgentBannerCenter
    @ObservedObject private var motion = MotionPreferences.shared
    let focus: (AgentEvent) -> Void

    var body: some View {
        VStack(alignment: .trailing, spacing: 6) {
            ForEach(center.banners) { banner in
                AgentBannerCard(event: banner.event) {
                    focus(banner.event)
                    center.dismiss(banner.id)
                } dismiss: {
                    center.dismiss(banner.id)
                }
                .transition(motion.animates(.toasts)
                    ? .asymmetric(insertion: .move(edge: .top).combined(with: .opacity), removal: .opacity)
                    : .identity)
            }
        }
        .padding(.trailing, 12)
        .padding(.top, 8)
        .animation(motion.animation(.toasts, .smooth(duration: 0.2)), value: center.banners)
    }
}

private struct AgentBannerCard: View {
    let event: AgentEvent
    let focus: () -> Void
    let dismiss: () -> Void
    @State private var hovered = false

    var body: some View {
        let brand = AgentBrand.forAgent(event.agent)
        let tint = brand?.hueHex.map { Color(hex: $0) } ?? Theme.accent

        HStack(spacing: 9) {
            ZStack {
                Circle().fill(tint.opacity(0.18)).frame(width: 22, height: 22)
                if let brand {
                    AgentLogo(brand: brand, size: 12)
                } else {
                    OctetIcon("sparkle", size: 14).foregroundStyle(tint)
                }
            }
            VStack(alignment: .leading, spacing: 1) {
                HStack(spacing: 5) {
                    Text(event.label)
                        .font(Theme.uiFontMedium)
                        .foregroundStyle(Theme.textPrimary)
                        .lineLimit(1)
                    Text(event.kind.title)
                        .font(Theme.captionFont)
                        .foregroundStyle(event.kind == .needsInput ? tint : Theme.textSecondary)
                }
                if let detail {
                    Text(detail)
                        .font(Theme.captionFont)
                        .foregroundStyle(Theme.textTertiary)
                        .lineLimit(1)
                }
            }
            Spacer(minLength: 6)
            Button(action: dismiss) {
                OctetIcon("xmark", size: 15)
                    .foregroundStyle(Theme.textTertiary)
                    .frame(width: 18, height: 18)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .opacity(hovered ? 1 : 0)
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 8)
        .frame(width: 290, alignment: .leading)
        .background {
            ZStack {
                Theme.card
                // The agent's own colour, fading out to the right.
                LinearGradient(
                    colors: [tint.opacity(0.26), tint.opacity(0)],
                    startPoint: .leading, endPoint: .trailing
                )
                .frame(width: 145)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
        .clipShape(RoundedRectangle(cornerRadius: 8))
        .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(hovered ? tint.opacity(0.5) : Theme.border, lineWidth: 1))
        .shadow(color: .black.opacity(0.3), radius: 14, y: 5)
        .contentShape(Rectangle())
        .onHover { hovered = $0 }
        .onTapGesture(perform: focus)
        .help("Go to \(event.label)")
    }

    private var detail: String? {
        let worked = AgentActivityWatcher.durationLabel(event.workedFor).map { "worked \($0)" }
        let name = AgentBrand.forAgent(event.agent)?.displayName
        return [name, worked].compactMap { $0 }.joined(separator: " · ").isEmpty
            ? nil
            : [name, worked].compactMap { $0 }.joined(separator: " · ")
    }
}
