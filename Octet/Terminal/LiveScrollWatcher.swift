import SwiftUI

/// Watches the panes on screen for being scrolled back while output keeps
/// arriving, and offers the way back: "↓ 26 new lines". Scroll changes come
/// as events for named panes only, so each window's watcher follows the
/// panes it shows.
@MainActor
final class LiveScrollWatcher: ObservableObject {

    /// What each scrolled-back pane's pill says; a pane at the bottom has none.
    @Published private(set) var pills: [String: String] = [:]

    private var trackers: [String: LiveScrollTracker] = [:]
    private var watched: Set<String> = []
    private var subscription: Subscription?
    private var client: EngineClient?

    /// One subscription's connection, ended from the main thread when the
    /// watched panes change while its thread reads.
    private final class Subscription: @unchecked Sendable {
        private let lock = NSLock()
        private var connection: EngineSocketConnection?
        private var cancelled = false

        var isCancelled: Bool { lock.withLock { cancelled } }

        /// Keeps the connection to end later; false once cancelled.
        func adopt(_ connection: EngineSocketConnection) -> Bool {
            lock.withLock {
                guard !cancelled else { return false }
                self.connection = connection
                return true
            }
        }

        func cancel() {
            lock.withLock {
                cancelled = true
                connection?.shutdownNow()
                connection = nil
            }
        }
    }

    /// Follows `paneIds`, resubscribing only when the set changes.
    func watch(_ paneIds: Set<String>, client: EngineClient) {
        self.client = client
        guard paneIds != watched else { return }
        watched = paneIds
        trackers = trackers.filter { paneIds.contains($0.key) }
        publish()
        subscription?.cancel()
        subscription = nil
        guard !paneIds.isEmpty else { return }
        let subscription = Subscription()
        self.subscription = subscription
        let subscriptions = paneIds.sorted().map { ["type": "pane.scroll_changed", "pane_id": $0] }
        let socketPath = client.socketPath
        let thread = Thread { [weak self] in
            // A dropped connection (the server restarting) is retried until
            // the watched set changes.
            while !subscription.isCancelled {
                do {
                    let connection = try EngineSocketConnection(path: socketPath)
                    guard subscription.adopt(connection) else { return connection.shutdownNow() }
                    try connection.send(["id": "octet-scroll", "method": "events.subscribe",
                                         "params": ["subscriptions": subscriptions]])
                    _ = try EngineClient.parseResponse(try connection.readLine())
                    while true {
                        let line = try connection.readLine()
                        guard let object = try? JSONSerialization.jsonObject(with: line) as? [String: Any],
                              let event = PaneScroll.parseEvent(object) else { continue }
                        DispatchQueue.main.async {
                            MainActor.assumeIsolated {
                                guard let self, !subscription.isCancelled else { return }
                                self.apply(event.scroll, to: event.paneId)
                            }
                        }
                    }
                } catch {
                    Thread.sleep(forTimeInterval: 1)
                }
            }
        }
        thread.name = "octet.scroll-events"
        thread.start()
    }

    private func apply(_ scroll: PaneScroll, to paneId: String) {
        var tracker = trackers[paneId] ?? LiveScrollTracker()
        tracker.update(scroll)
        trackers[paneId] = tracker
        publish()
    }

    private func publish() {
        var pills: [String: String] = [:]
        for (paneId, tracker) in trackers where !tracker.isLive { pills[paneId] = tracker.label }
        guard pills != self.pills else { return }
        self.pills = pills
        DebugSnapshot.overlay("live-scroll", !pills.isEmpty)
    }

    /// Back to the bottom of `paneId`, where the output is.
    func jumpToLive(_ paneId: String) {
        guard let client else { return }
        DispatchQueue.global(qos: .userInitiated).async {
            _ = try? client.call("pane.scroll", ["pane_id": paneId, "offset_from_bottom": 0])
        }
        OctetTerminalRuntime.focusTerminal()
    }
}

/// The pills over the panes of the tab in front, each at the foot of its pane.
struct LiveScrollPills: View {
    @ObservedObject var watcher: LiveScrollWatcher
    let layout: EngineLayout?

    var body: some View {
        GeometryReader { proxy in
            ForEach(Array(watcher.pills.keys.sorted()), id: \.self) { paneId in
                if let frame = layout?.frame(ofPane: paneId, in: proxy.size), let label = watcher.pills[paneId] {
                    LiveScrollPill(label: label) { watcher.jumpToLive(paneId) }
                        .position(x: frame.midX, y: frame.maxY - 26)
                }
            }
        }
        .allowsHitTesting(!watcher.pills.isEmpty)
    }
}

private struct LiveScrollPill: View {
    let label: String
    let action: () -> Void
    @State private var hovered = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: 6) {
                OctetIcon("arrow.down", size: 11)
                Text(label).font(Theme.captionFont.weight(.medium))
            }
            .foregroundStyle(Theme.textPrimary)
            .padding(.horizontal, 11)
            .frame(height: 26)
            .background(Capsule().fill(hovered ? Theme.cardSelected : Theme.chrome))
            .overlay(Capsule().strokeBorder(Theme.divider, lineWidth: 1))
            .shadow(color: .black.opacity(0.25), radius: 8, y: 2)
        }
        .buttonStyle(.plain)
        .onHover { hovered = $0 }
        .help("Scroll to the latest output")
        .accessibilityLabel("\(label). Scroll to the latest output")
    }
}
