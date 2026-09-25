import AppKit
import SwiftUI

/// What a program in a pane asks of the person: the bell (BEL) and desktop
/// notifications (OSC 9 and 777), as other terminals honour them.
@MainActor
enum TerminalAttention {
    /// The Dock icon bounces once when Octet isn't in front; in front, the
    /// system alert sound, if agent sounds are on.
    static func bell() {
        if NSApp.isActive {
            if SettingsStore.shared.values.agentSounds { NSSound.beep() }
        } else {
            NSApp.requestUserAttention(.informationalRequest)
        }
    }

    /// Shown as Octet's own banner when that's how notices are delivered.
    static func notify(title: String, body: String) {
        let heading = title.isEmpty ? "Terminal" : title
        // With system notifications on, the session server delivers them itself.
        guard SettingsStore.shared.values.notifications == .banner else { return }
        ToastCenter.shared.info(heading, detail: body.isEmpty ? nil : body, after: 6)
        if !NSApp.isActive { NSApp.requestUserAttention(.informationalRequest) }
    }
}

/// The link under the pointer, for the preview in the terminal's corner.
@MainActor
final class HoverLink: ObservableObject {
    static let shared = HoverLink()
    @Published var url: String?
}

/// Where a link goes, before you ⌘-click it.
struct HoverLinkPreview: View {
    @ObservedObject var link = HoverLink.shared

    var body: some View {
        if let url = link.url {
            HStack(spacing: 6) {
                Image(systemName: "link").font(.system(size: 10, weight: .semibold))
                Text(url).lineLimit(1).truncationMode(.middle)
                Text("⌘-click to open").foregroundStyle(Theme.textTertiary)
            }
            .font(Theme.captionFont)
            .foregroundStyle(Theme.textSecondary)
            .padding(.horizontal, 8)
            .frame(height: 22)
            .frame(maxWidth: 560, alignment: .leading)
            .background(RoundedRectangle(cornerRadius: 5).fill(Theme.chrome))
            .overlay(RoundedRectangle(cornerRadius: 5).strokeBorder(Theme.border, lineWidth: 1))
            .padding(8)
            .allowsHitTesting(false)
            .onAppear { DebugSnapshot.overlay("hover-link", true) }
            .onDisappear { DebugSnapshot.overlay("hover-link", false) }
        }
    }
}
