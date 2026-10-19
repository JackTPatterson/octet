import SwiftUI

extension AgentLocation {
    /// Worktrees in violet and other repositories in blue, the Tokyo Night
    /// hues the app already warns in; a folder of the same checkout stays
    /// neutral, since it is still the same code.
    var tint: Color {
        switch kind {
        case .worktree: return Color(hex: "bb9af7")
        case .repository: return Color(hex: "7aa2f7")
        case .subfolder, .folder: return Theme.textSecondary
        }
    }
}

/// Where one or more of a workspace's agents went: the place's mark and a
/// short name, with how many agents are there when more than one. Flat, no
/// box: it's a line of detail under the row's title.
struct AgentLocationChip: View {
    let location: AgentLocation
    var count = 1

    var body: some View {
        HStack(spacing: 4) {
            OctetIcon(location.icon, size: 11)
            Text(location.shortName)
                .lineLimit(1)
                .truncationMode(.tail)
            if count > 1 {
                Text("×\(count)")
                    .foregroundStyle(location.tint.opacity(0.7))
            }
        }
        .font(Theme.captionFont)
        .foregroundStyle(location.tint)
        .fixedSize()
        .help(location.help(abbreviate: abbreviateHome) + (count > 1 ? "\n\(count) agents here" : ""))
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(count > 1 ? "\(count) agents" : "Agent") in \(location.phrase)")
    }
}

/// The places a workspace's agents are spread over, in a line, with the
/// rest counted once the row is full; the count opens the whole list.
struct AgentLocationRow: View {
    let locations: [(location: AgentLocation, count: Int)]
    var limit = 2
    @ObservedObject private var motion = MotionPreferences.shared

    var body: some View {
        HStack(spacing: 10) {
            ForEach(locations.prefix(limit), id: \.location.root) { entry in
                AgentLocationChip(location: entry.location, count: entry.count)
                    .layoutPriority(entry.location.kind == .worktree ? 1 : 0)
                    .transition(motion.animates(.connections)
                        ? .scale(scale: 0.6).combined(with: .opacity) : .identity)
            }
            if locations.count > limit {
                Button(action: showAll) {
                    Text("+\(locations.count - limit)")
                        .font(Theme.captionFont)
                        .foregroundStyle(Theme.textTertiary)
                        .padding(.horizontal, 4)
                        .background(RoundedRectangle(cornerRadius: 4).fill(Theme.hover.opacity(0.7)))
                }
                .buttonStyle(.plain)
                .help("Every place an agent is working")
                .accessibilityLabel("\(locations.count - limit) more places")
            }
            Spacer(minLength: 0)
        }
        .animation(motion.animation(.connections, .spring(response: 0.4, dampingFraction: 0.7)),
                   value: locations.map(\.location.root))
    }

    /// Every place, each with its branch and how many agents are there.
    private func showAll() {
        var items: [OctetMenuItem] = [.header("Agents are working in")]
        for entry in locations {
            let place = entry.location
            let branch = place.branch.map { " · \($0)" } ?? ""
            let agents = entry.count > 1 ? " · \(entry.count) agents" : ""
            items.append(.action(place.shortName + branch + agents, icon: place.icon,
                                 help: abbreviateHome(place.path)) {
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(place.path, forType: .string)
            })
        }
        items.append(.divider)
        items.append(.header("Choosing one copies its path"))
        OctetContextMenu.present(items)
    }
}
