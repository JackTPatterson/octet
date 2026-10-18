import AppKit
import Combine
import SwiftUI

/// "+12 −3": lines added and removed, the same everywhere they're shown,
/// green and red, in counts that stay narrow (1.2k). Zero sides are left
/// out; `compactCounts` off shows the exact numbers.
struct DiffStatLabel: View {
    let added: Int
    let removed: Int
    var compactCounts = true
    /// Caption size in lists; the status bar sets its own 11.5pt.
    var font: Font = Theme.captionFont

    var body: some View {
        HStack(spacing: 4) {
            if added > 0 {
                Text("+" + format(added)).foregroundStyle(Color(hex: AgentStateColor.done))
            }
            if removed > 0 {
                Text("\u{2212}" + format(removed)).foregroundStyle(Theme.danger)
            }
        }
        .font(font.monospacedDigit())
        .help("\(added) line\(added == 1 ? "" : "s") added, \(removed) removed")
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("\(added) additions, \(removed) deletions")
    }

    private func format(_ value: Int) -> String { compactCounts ? CompactFormat.count(value) : String(value) }
}

/// How long something has been running, counting up each second, for as
/// long as it's on screen.
struct ElapsedLabel: View {
    let since: Date

    var body: some View {
        TimelineView(.periodic(from: since, by: 1)) { context in
            Text(CompactFormat.elapsed(context.date.timeIntervalSince(since)))
                .monospacedDigit()
        }
    }
}

/// A copy button that turns into a check once it's copied, for a message.
struct CopyMessageButton: View {
    let text: String
    @State private var copied = false

    var body: some View {
        Button {
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(text, forType: .string)
            ClipboardWatcher.shared.acknowledge()
            withAnimation(.easeOut(duration: 0.15)) { copied = true }
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.4) {
                withAnimation(.easeOut(duration: 0.2)) { copied = false }
            }
        } label: {
            OctetIcon(copied ? "checkmark" : "doc.on.doc", size: 11)
                .foregroundStyle(copied ? Theme.accent : Theme.textTertiary)
                .frame(width: 22, height: 20)
                .background(RoundedRectangle(cornerRadius: 5).fill(Theme.chrome))
                .overlay(RoundedRectangle(cornerRadius: 5).strokeBorder(Theme.border, lineWidth: 1))
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help(copied ? "Copied" : "Copy as Markdown")
        .accessibilityLabel(copied ? "Copied" : "Copy message")
    }
}

