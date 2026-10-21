import SwiftUI

/// Watches the panes on screen for being scrolled back while output keeps
/// arriving, and offers the way back: "↓ 26 new lines". Each pane's terminal
/// scrolls itself, so it's read from there (`PaneGeometry`).
@MainActor
final class LiveScrollWatcher: ObservableObject {

    /// What each scrolled-back pane's pill says; a pane at the bottom has none.
    @Published private(set) var pills: [String: String] = [:]

    private var trackers: [String: LiveScrollTracker] = [:]

    /// Takes where each pane on screen is scrolled to now.
    func follow(_ panes: [String: PaneGeometry.Pane]) {
        trackers = trackers.filter { panes[$0.key] != nil }
        for (paneId, pane) in panes {
            guard let scroll = pane.scroll else { continue }
            var tracker = trackers[paneId] ?? LiveScrollTracker()
            tracker.update(scroll)
            trackers[paneId] = tracker
        }
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
        PaneMirrorView.view(of: paneId)?.scroll(toOffsetFromBottom: 0)
        OctetTerminalRuntime.focusTerminal()
    }
}

/// The pills over the panes of the tab in front, each at the foot of its pane.
struct LiveScrollPills: View {
    @ObservedObject var watcher: LiveScrollWatcher
    @ObservedObject var geometry: PaneGeometry

    var body: some View {
        GeometryReader { _ in
            ForEach(Array(watcher.pills.keys.sorted()), id: \.self) { paneId in
                if let frame = geometry.panes[paneId]?.frame, let label = watcher.pills[paneId] {
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
