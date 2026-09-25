import AppKit
import SwiftUI

/// Over the terminal when its client has gone: the session server keeps the
/// workspaces, so the way on is to reconnect, not to quit.
struct TerminalDisconnectedCard: View {
    let reconnect: () -> Void

    var body: some View {
        ZStack {
            Theme.terminalBackground
            VStack(spacing: 10) {
                Image(systemName: "bolt.horizontal.circle").font(.system(size: 26)).foregroundStyle(Theme.textTertiary)
                Text("The terminal disconnected").font(.system(size: 14, weight: .semibold)).foregroundStyle(Theme.textPrimary)
                Text("Your workspaces and agents are still running in the session. Reconnect to pick up where you were.")
                    .font(Theme.uiFont).foregroundStyle(Theme.textSecondary)
                    .multilineTextAlignment(.center).frame(maxWidth: 380)
                HStack(spacing: 8) {
                    OctetButton(title: "Quit Octet", kind: .ghost, compact: true) { NSApp.terminate(nil) }
                    OctetButton(title: "Reconnect", kind: .primary, compact: true, action: reconnect)
                        .keyboardShortcut(.defaultAction)
                }
                .padding(.top, 4)
            }
        }
        .onAppear { DebugSnapshot.overlay("disconnected", true) }
        .onDisappear { DebugSnapshot.overlay("disconnected", false) }
    }
}
