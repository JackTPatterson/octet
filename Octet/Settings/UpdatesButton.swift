import Sparkle
import SwiftUI

/// What's waiting to be updated, for the title bar's updates button: a new
/// Octet that Sparkle found, and agent tools with newer releases.
@MainActor
final class AppUpdateStatus: ObservableObject {
    static let shared = AppUpdateStatus()

    /// The version Sparkle found and the person hasn't installed or skipped.
    @Published var version: String?
    /// Asks Sparkle to check, which shows its card again for a waiting one.
    var check: (() -> Void)?
}

/// The title bar's updates button: an arrow that gains a dot when Octet or
/// an agent tool has an update waiting. A click lists what to do about it.
struct UpdatesButton: View {
    @ObservedObject private var app = AppUpdateStatus.shared
    @ObservedObject private var agents = AgentUpdateCenter.shared
    @State private var hovered = false

    private var waiting: Bool { app.version != nil || !agents.waiting.isEmpty }

    private var help: String {
        var parts: [String] = []
        if let version = app.version { parts.append("Octet \(version) is available") }
        if !agents.waiting.isEmpty {
            parts.append(agents.waiting.count == 1 ? "An update for \(agents.waiting[0].displayName)"
                                                  : "\(agents.waiting.count) agent updates")
        }
        return parts.isEmpty ? "Updates: everything is current" : parts.joined(separator: " · ")
    }

    var body: some View {
        Button(action: open) {
            OctetIcon("arrow.down.circle", size: 15)
                .foregroundStyle(waiting || hovered ? Theme.textPrimary : Theme.textSecondary)
                .frame(width: 24, height: 24)
                .background(RoundedRectangle(cornerRadius: Theme.controlRadius).fill(hovered ? Theme.hover : .clear))
                .overlay(alignment: .topTrailing) {
                    if waiting {
                        Circle().fill(HubStyle.waiting).frame(width: 7, height: 7)
                            .overlay(Circle().strokeBorder(Theme.chrome, lineWidth: 1.5))
                            .offset(x: -2, y: 2)
                    }
                }
                .contentShape(Rectangle())
        }
        .buttonStyle(OctetPressStyle())
        .onHover { hovered = $0 }
        .help(help)
        .accessibilityLabel(help)
    }

    private func open() {
        var items: [OctetMenuItem] = []
        if let version = app.version {
            items.append(.action("Update Octet to \(version)…", icon: "arrow.down.circle") { app.check?() })
        }
        if !agents.waiting.isEmpty {
            let count = agents.waiting.count
            items.append(.action(count == 1 ? "Update \(agents.waiting[0].displayName)…" : "Update \(count) Agent Tools…",
                                 icon: "arrow.down.circle") { agents.reopen() })
        }
        if items.isEmpty { items.append(.header("Everything is up to date")) }
        items.append(.divider)
        items.append(.action("Check for Updates", icon: "arrow.clockwise") {
            app.check?()
            AgentUpdatePrompter.shared.check(AgentDiscoveryStore.shared.agents, force: true)
        })
        OctetContextMenu.present(items)
    }
}
