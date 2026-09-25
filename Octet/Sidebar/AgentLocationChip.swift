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

/// Where one or more of a workspace's agents went: the place's mark, its
/// name, and how many agents are there when more than one.
struct AgentLocationChip: View {
    let location: AgentLocation
    var count = 1

    var body: some View {
        HStack(spacing: 4) {
            OctetIcon(location.icon, size: 10)
            Text(location.name)
                .lineLimit(1)
                .truncationMode(.middle)
            if count > 1 {
                Text("\(count)")
                    .foregroundStyle(location.tint.opacity(0.7))
            }
        }
        .font(Theme.captionFont)
        .foregroundStyle(location.tint)
        .padding(.horizontal, 5)
        .frame(height: 16)
        .background(RoundedRectangle(cornerRadius: 4).fill(location.tint.opacity(0.12)))
        .overlay(RoundedRectangle(cornerRadius: 4).strokeBorder(location.tint.opacity(0.35)))
        .help(location.help(abbreviate: abbreviateHome) + (count > 1 ? "\n\(count) agents here" : ""))
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(count > 1 ? "\(count) agents" : "Agent") in \(location.phrase)")
    }
}

/// The places a workspace's agents are spread over, a chip each, with the
/// rest counted once the row is full.
struct AgentLocationRow: View {
    let locations: [(location: AgentLocation, count: Int)]
    var limit = 2
    @ObservedObject private var motion = MotionPreferences.shared

    var body: some View {
        HStack(spacing: 4) {
            OctetIcon("tool.agent", size: 10)
                .foregroundStyle(Theme.textTertiary)
                .frame(width: 12)
            ForEach(locations.prefix(limit), id: \.location.root) { entry in
                AgentLocationChip(location: entry.location, count: entry.count)
                    .layoutPriority(entry.location.kind == .worktree ? 1 : 0)
                    .transition(motion.animates(.connections)
                        ? .scale(scale: 0.6).combined(with: .opacity) : .identity)
            }
            if locations.count > limit {
                Text("+\(locations.count - limit)")
                    .font(Theme.captionFont)
                    .foregroundStyle(Theme.textTertiary)
                    .help(locations.dropFirst(limit).map(\.location.phrase).joined(separator: "\n"))
            }
            Spacer(minLength: 0)
        }
        .animation(motion.animation(.connections, .spring(response: 0.4, dampingFraction: 0.7)),
                   value: locations.map(\.location.root))
    }
}
