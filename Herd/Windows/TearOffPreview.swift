import AppKit
import SwiftUI

/// What a tab dragged out of every window will become: a small window that
/// follows the cursor, the way Chrome and Safari show a tab being torn off,
/// and that grows into the new window's frame when the tab is let go.
@MainActor
final class TearOffPreview {
    static let shared = TearOffPreview()

    /// How big the preview is while it follows the cursor, against the
    /// window it will become.
    private static let scale: CGFloat = 0.42
    private var panel: NSPanel?
    private var hosting: NSHostingView<TearOffCard>?
    /// Where the window would open if the tab were let go now.
    private(set) var target: CGRect?
    private var size = CGSize(width: 1280, height: 820)

    var window: NSWindow? { panel }
    var isShowing: Bool { panel?.isVisible == true }

    /// Starts a drag of the tab titled `title`, opening at `size`.
    func prepare(title: String, agent: String?, size: CGSize) {
        self.size = size
        let card = TearOffCard(title: title, agent: agent)
        if let hosting { hosting.rootView = card } else {
            let panel = NSPanel(contentRect: .zero, styleMask: [.borderless, .nonactivatingPanel],
                                backing: .buffered, defer: true)
            panel.isOpaque = false
            panel.backgroundColor = .clear
            panel.hasShadow = true
            panel.level = .floating
            panel.ignoresMouseEvents = true
            panel.isReleasedWhenClosed = false
            panel.collectionBehavior = [.canJoinAllSpaces, .transient, .ignoresCycle]
            let hosting = NSHostingView(rootView: card)
            panel.contentView = hosting
            self.panel = panel
            self.hosting = hosting
        }
    }

    /// Follows the cursor at `point` (screen coordinates).
    func follow(_ point: CGPoint) {
        guard let panel else { return }
        let frame = WindowActions.tearOffFrame(at: point, size: size)
        target = frame
        let small = CGRect(x: point.x - 60 * Self.scale, y: point.y - frame.height * Self.scale + 20 * Self.scale,
                           width: frame.width * Self.scale, height: frame.height * Self.scale)
        if !panel.isVisible {
            panel.setFrame(small, display: true)
            panel.alphaValue = 0
            panel.orderFrontRegardless()
            animate { panel.animator().alphaValue = 1 }
        } else {
            panel.setFrame(small, display: true)
        }
    }

    /// Back over a window: its drop targets take over.
    func hide() {
        target = nil
        guard let panel, panel.isVisible else { return }
        animate({ panel.animator().alphaValue = 0 }, done: { if panel.alphaValue == 0 { panel.orderOut(nil) } })
    }

    /// Let go: grows into the new window's frame, then gets out of its way.
    func land(in frame: CGRect) {
        target = nil
        guard let panel, panel.isVisible else { return }
        guard MotionPreferences.shared.animates(.tabs) else { return panel.orderOut(nil) }
        NSAnimationContext.runAnimationGroup { context in
            context.duration = 0.2
            context.timingFunction = CAMediaTimingFunction(name: .easeOut)
            panel.animator().setFrame(frame, display: true)
        } completionHandler: {
            MainActor.assumeIsolated {
                // The window opens underneath; the card fades off it.
                NSAnimationContext.runAnimationGroup({ context in
                    context.duration = 0.18
                    panel.animator().alphaValue = 0
                }, completionHandler: { MainActor.assumeIsolated { panel.orderOut(nil) } })
            }
        }
    }

    private func animate(_ change: () -> Void, done: (@MainActor () -> Void)? = nil) {
        guard MotionPreferences.shared.animates(.tabs) else {
            change()
            panel?.alphaValue = panel?.alphaValue ?? 1
            done?()
            return
        }
        NSAnimationContext.runAnimationGroup({ context in
            context.duration = 0.12
            change()
        }, completionHandler: { MainActor.assumeIsolated { done?() } })
    }
}

/// The preview's drawing: a Herd window in miniature, holding the one tab.
struct TearOffCard: View {
    let title: String
    let agent: String?

    var body: some View {
        GeometryReader { proxy in
            let bar = max(18, proxy.size.height * 0.07)
            VStack(spacing: 0) {
                HStack(spacing: 5) {
                    ForEach(0..<3, id: \.self) { _ in
                        Circle().fill(Theme.textTertiary.opacity(0.45)).frame(width: 7, height: 7)
                    }
                    Spacer()
                }
                .padding(.horizontal, 9)
                .frame(height: bar)
                HStack(spacing: 6) {
                    if let brand = AgentBrand.forAgent(agent) {
                        AgentLogo(brand: brand, size: 11)
                    } else {
                        HerdIcon("terminal", size: 11).foregroundStyle(Theme.textSecondary)
                    }
                    Text(title)
                        .font(Theme.uiFont)
                        .foregroundStyle(Theme.textPrimary)
                        .lineLimit(1)
                }
                .padding(.horizontal, 10)
                .frame(height: bar)
                .background(Theme.terminalBackground)
                .overlay(alignment: .top) { Rectangle().fill(Theme.accent).frame(height: 2) }
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(Theme.chrome)
                Theme.terminalBackground
            }
        }
        .background(Theme.chrome)
        // The theme's colors can carry the terminal's transparency; a
        // preview should read as a solid window.
        .background(Color(nsColor: .windowBackgroundColor))
        .clipShape(RoundedRectangle(cornerRadius: 10))
        .overlay(RoundedRectangle(cornerRadius: 10).strokeBorder(Theme.accent.opacity(0.55), lineWidth: 1))
    }
}
