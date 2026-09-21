import SwiftUI

/// Lists agent sessions killed by a shutdown or session server restart (or, from the
/// palette, recent sessions that aren't running) and resumes the chosen ones.
struct RecoveryPanel: View {
    @ObservedObject var recovery: AgentRecoveryController
    @State private var excluded: Set<String> = []

    var body: some View {
        let sessions = recovery.offered
        let selected = sessions.filter { !excluded.contains($0.id) }

        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 8) {
                OctetIcon("arrow.counterclockwise.circle.fill", size: 19)
                    .foregroundStyle(Theme.accent)
                VStack(alignment: .leading, spacing: 1) {
                    Text(recovery.showingHistory ? "Recent Agent Sessions" : "Recover Agent Sessions")
                        .font(Theme.uiFontMedium)
                        .foregroundStyle(Theme.textPrimary)
                    Text(recovery.showingHistory
                         ? "Not running now. Resume any of them in its workspace."
                         : "\(sessions.count) session\(sessions.count == 1 ? " was" : "s were") running when the terminal stopped.")
                        .font(Theme.captionFont)
                        .foregroundStyle(Theme.textSecondary)
                }
                Spacer()
            }
            .padding(12)

            Rectangle().fill(Theme.divider).frame(height: 1)

            // A ScrollView takes whatever height it is given, which left a
            // panel of empty space under a single session.
            ScrollView {
                VStack(spacing: 2) {
                    ForEach(sessions) { record in
                        RecoveryRow(
                            record: record,
                            included: !excluded.contains(record.id),
                            toggle: {
                                if excluded.contains(record.id) { excluded.remove(record.id) } else { excluded.insert(record.id) }
                            },
                            copy: { recovery.copyCommand(record) }
                        )
                    }
                }
                .padding(6)
            }
            .frame(height: min(260, CGFloat(sessions.count) * 42 + 12))

            Rectangle().fill(Theme.divider).frame(height: 1)

            HStack {
                // No Return/Esc shortcuts: the panel isn't modal, so those
                // keys belong to the terminal you keep typing in.
                Button(recovery.showingHistory ? "Close" : "Dismiss") { recovery.dismiss() }
                Spacer()
                Button(selected.count == sessions.count && sessions.count > 1 ? "Resume All" : "Resume \(selected.count)") {
                    recovery.resume(selected)
                }
                .disabled(selected.isEmpty)
            }
            .padding(10)
        }
        .frame(width: 380)
        .background(Theme.card)
        .clipShape(RoundedRectangle(cornerRadius: 8))
        .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(Theme.border, lineWidth: 1))
        .shadow(color: .black.opacity(0.35), radius: 18, y: 8)
        .onChange(of: recovery.offered.map(\.id)) { _, ids in
            excluded.formIntersection(ids)
        }
    }
}

private struct RecoveryRow: View {
    let record: AgentSessionRecord
    let included: Bool
    let toggle: () -> Void
    let copy: () -> Void
    @State private var hovered = false

    var body: some View {
        let brand = AgentBrand.forAgent(record.agent)
        HStack(spacing: 8) {
            OctetIcon(included ? "checkmark.square.fill" : "square", size: 16)
                .foregroundStyle(included ? Theme.accent : Theme.textTertiary)
            if let brand { AgentLogo(brand: brand, size: 13) }
            VStack(alignment: .leading, spacing: 1) {
                Text(title)
                    .font(Theme.uiFont)
                    .foregroundStyle(Theme.textPrimary)
                    .lineLimit(1)
                Text(subtitle)
                    .font(Theme.captionFont)
                    .foregroundStyle(Theme.textTertiary)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
            Spacer(minLength: 4)
            Text(WorkspaceActivity.ageLabel(since: record.lastSeen))
                .font(Theme.captionFont)
                .foregroundStyle(Theme.textTertiary)
            Button(action: copy) {
                OctetIcon("doc.on.doc", size: 14)
                    .foregroundStyle(Theme.textSecondary)
                    .frame(width: 20, height: 20)
            }
            .buttonStyle(.plain)
            .opacity(hovered ? 1 : 0)
            .help(record.resumeCommand ?? "")
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 6)
        .background(hovered ? Theme.hover : Color.clear)
        .clipShape(RoundedRectangle(cornerRadius: Theme.rowRadius))
        .contentShape(Rectangle())
        .onHover { hovered = $0 }
        .onTapGesture(perform: toggle)
    }

    private var title: String {
        let name = AgentRecoveryController.displayName(record)
        return record.tabLabel.isEmpty || record.tabLabel == record.agent ? name : "\(name) · \(record.tabLabel)"
    }

    private var subtitle: String {
        let folder = record.cwd.replacingOccurrences(of: NSHomeDirectory(), with: "~")
        return record.workspaceLabel.isEmpty ? folder : "\(record.workspaceLabel) · \(folder)"
    }
}
