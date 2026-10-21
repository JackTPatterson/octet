import SwiftUI

/// Notices in the top-right of the window in front: an agent finished, or
/// it is waiting on you. Click one to go to it. Which notices become
/// banners is `AttentionRouter`'s call; this only shows them, the way
/// toasts are shown: in one window, held while the pointer is on them.
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
    /// When each banner goes; one under the pointer is held, with what it had left.
    private var deadlines: [String: Date] = [:]
    private var held: [String: TimeInterval] = [:]

    /// The session server's agent events, from each snapshot: routed, so
    /// each becomes one notice at most (a banner, a notification, a peek).
    func show(_ events: [AgentEvent]) {
        guard !events.isEmpty else { return }
        AttentionRouter.shared.route(events)
    }

    /// Shows one banner (the router decided it should be one). A newer
    /// notice from the same agent replaces its last.
    func present(_ event: AgentEvent) {
        guard !banners.contains(where: { $0.id == event.id }) else { return }
        for old in banners where old.event.agentKey == event.agentKey { dismiss(old.id) }
        banners.append(Banner(event: event))
        schedule(event.id, after: Self.lifetime)
        if banners.count > Self.maxVisible, let oldest = banners.first { dismiss(oldest.id) }
    }

    /// Sends the notices to the phone topic in Settings, while you're away
    /// from Octet (it isn't in front).
    func pushToPhone(_ events: [AgentEvent]) {
        let settings = SettingsStore.shared.values
        guard PhonePush.offered, !settings.phoneTopic.isEmpty, !NSApp.isActive else { return }
        for event in events {
            let name = AgentBrand.forAgent(event.agent)?.displayName ?? event.agent ?? "An agent"
            guard let request = PhonePush.request(server: settings.phoneServer, topic: settings.phoneTopic,
                                                  event: event, agentName: name) else { continue }
            URLSession.shared.dataTask(with: request).resume()
        }
    }

    func dismiss(_ id: String) {
        banners.removeAll { $0.id == id }
        deadlines[id] = nil
        held[id] = nil
    }

    func dismissAll() {
        banners.removeAll()
        deadlines = [:]
        held = [:]
    }

    /// The pointer is on a banner: it stays until the pointer leaves.
    func hold(_ id: String) {
        guard let deadline = deadlines[id] else { return }
        held[id] = max(2, deadline.timeIntervalSinceNow)
        deadlines[id] = nil
    }

    /// The pointer left: the banner gets what time it had left, at least 2s.
    func release(_ id: String) {
        guard let remaining = held.removeValue(forKey: id) else { return }
        schedule(id, after: remaining)
    }

    private func schedule(_ id: String, after seconds: TimeInterval) {
        let deadline = Date().addingTimeInterval(seconds)
        deadlines[id] = deadline
        DispatchQueue.main.asyncAfter(deadline: .now() + seconds) { [weak self] in
            guard let self, self.deadlines[id] == deadline else { return }
            self.dismiss(id)
        }
    }
}

struct AgentBannerStack: View {
    @ObservedObject var center: AgentBannerCenter
    @ObservedObject private var motion = MotionPreferences.shared
    @StateObject private var host = HostWindow()
    let focus: (AgentEvent) -> Void

    var body: some View {
        VStack(alignment: .trailing, spacing: Theme.Space.sm) {
            // Like toasts, banners follow you: only the window in front has them.
            ForEach(host.isFront ? center.banners : []) { banner in
                AgentBannerCard(event: banner.event) {
                    center.dismiss(banner.id)
                    // A conversation's banner has no pane: the router knows where it is.
                    if banner.event.sessionId != nil { AttentionRouter.shared.open(banner.event) } else { focus(banner.event) }
                } dismiss: {
                    center.dismiss(banner.id)
                } hover: { inside in
                    if inside { center.hold(banner.id) } else { center.release(banner.id) }
                }
                .transition(motion.animates(.toasts)
                    ? .asymmetric(insertion: .move(edge: .top).combined(with: .opacity), removal: .opacity)
                    : .identity)
            }
        }
        .padding(.trailing, Theme.Space.lg)
        .padding(.top, Theme.Space.md)
        .animation(motion.animation(.toasts, .smooth(duration: 0.2)), value: center.banners)
        .background(HostWindowReader(host: host))
    }
}

private struct AgentBannerCard: View {
    let event: AgentEvent
    let open: () -> Void
    let dismiss: () -> Void
    let hover: (Bool) -> Void
    @State private var hovered = false

    var body: some View {
        let brand = AgentBrand.forAgent(event.agent)
        let tint = brand?.hueHex.map { Color(hex: $0) } ?? Theme.accent
        let state = event.state ?? (event.kind == .finished ? .done : .needsInput)

        HStack(spacing: Theme.Space.md) {
            Button(action: open) {
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
                                .font(Theme.Text.bodyMedium)
                                .foregroundStyle(Theme.textPrimary)
                                .lineLimit(1)
                            Text(event.phrase)
                                .font(Theme.Text.caption)
                                .foregroundStyle(state.needsYou ? state.color : Theme.textSecondary)
                        }
                        if let detail {
                            Text(detail)
                                .font(Theme.Text.caption)
                                .foregroundStyle(Theme.textTertiary)
                                .lineLimit(1)
                        }
                    }
                    Spacer(minLength: Theme.Space.sm)
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .help("Go to \(event.label)")
            .accessibilityLabel("\(AgentBrand.forAgent(event.agent)?.displayName ?? "Agent") \(event.phrase): \(event.label)")
            .accessibilityHint("Goes to it")
            // Always there for keyboard and VoiceOver; drawn faint until hovered.
            OctetIconButton(icon: "xmark", help: "Dismiss", compact: true, action: dismiss)
                .opacity(hovered ? 1 : 0.35)
        }
        .padding(.leading, 10)
        .padding(.trailing, Theme.Space.xs)
        .padding(.vertical, Theme.Space.md)
        .frame(width: 290, alignment: .leading)
        .background {
            // The agent's own colour, fading out to the right.
            LinearGradient(colors: [tint.opacity(0.26), tint.opacity(0)], startPoint: .leading, endPoint: .trailing)
                .frame(width: 145)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        .octetGlass(cornerRadius: Theme.Radius.card, fill: Theme.card)
        .overlay(RoundedRectangle(cornerRadius: Theme.Radius.card, style: .continuous)
            .strokeBorder(hovered ? tint.opacity(0.5) : .clear, lineWidth: 1))
        .onHover { inside in
            hovered = inside
            hover(inside)
        }
        .accessibilityElement(children: .contain)
    }

    private var detail: String? {
        let worked = AgentActivityWatcher.durationLabel(event.workedFor).map { "worked \($0)" }
        let parts = [event.detail ?? AgentBrand.forAgent(event.agent)?.displayName, worked].compactMap { $0 }.filter { !$0.isEmpty }
        return parts.isEmpty ? nil : parts.joined(separator: " · ")
    }
}
