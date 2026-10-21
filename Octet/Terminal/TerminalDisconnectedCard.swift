import AppKit
import SwiftUI

/// Over the terminal when its client has gone: the session server keeps the
/// workspaces, so the way on is to reconnect, not to quit. It says what went,
/// the client or the server too, and tries again by itself once the server
/// answers.
struct TerminalDisconnectedCard: View {
    /// Whether the session server still answers Octet.
    let serverReachable: Bool
    /// A reconnect was tried a moment ago and the terminal went again.
    let retryFailed: Bool
    let reconnect: () -> Void
    @State private var reconnecting = false

    var body: some View {
        ZStack {
            Theme.terminalBackground
            VStack(spacing: Theme.Space.md) {
                OctetIcon("bolt.horizontal.circle", size: 26).foregroundStyle(Theme.textTertiary)
                Text(title).font(Theme.Text.title3).foregroundStyle(Theme.textPrimary)
                Text("Your workspaces and agents are still running in the session. Reconnect to pick up where you were.")
                    .font(Theme.Text.body).foregroundStyle(Theme.textSecondary)
                    .multilineTextAlignment(.center).frame(maxWidth: 380)
                Text(detail)
                    .font(Theme.Text.caption).foregroundStyle(Theme.textTertiary)
                    .multilineTextAlignment(.center).frame(maxWidth: 380)
                    .textSelection(.enabled)
                if reconnecting {
                    HStack(spacing: Theme.Space.sm) {
                        LoadingLine(width: 28)
                        Text("Reconnecting…").font(Theme.Text.body).foregroundStyle(Theme.textSecondary)
                    }
                    .padding(.top, Theme.Space.xs)
                    .accessibilityElement(children: .combine)
                } else {
                    HStack(spacing: Theme.Space.md) {
                        OctetButton(title: "Quit Octet", kind: .ghost, compact: true) { NSApp.terminate(nil) }
                        OctetButton(title: retryFailed ? "Try Again" : "Reconnect", kind: .primary, compact: true) { start() }
                            .keyboardShortcut(.defaultAction)
                    }
                    .padding(.top, Theme.Space.xs)
                }
            }
        }
        .onAppear { DebugSnapshot.overlay("disconnected", true) }
        .onDisappear { DebugSnapshot.overlay("disconnected", false) }
        // The server came back: no need to wait for a click.
        .onChange(of: serverReachable) { _, reachable in if reachable, !reconnecting { start() } }
    }

    private var title: String {
        retryFailed ? "Couldn't reconnect the terminal" : "The terminal disconnected"
    }

    private var detail: String {
        serverReachable
            ? "The terminal's connection to the session ended; the session server is still answering."
            : "Octet can't reach the session server right now. It reconnects as soon as the server answers."
    }

    /// Shows the attempt for a moment before the terminal is rebuilt, so a
    /// quick failure reads as a retry rather than a flicker.
    private func start() {
        reconnecting = true
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.6) {
            reconnect()
            reconnecting = false
        }
    }
}
