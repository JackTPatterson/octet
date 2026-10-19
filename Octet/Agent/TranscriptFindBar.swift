import SwiftUI

/// Find in conversation, anchored top right of the transcript after T3 Code's
/// thread find bar: a field, "n of m", next and previous, and a case toggle.
/// Return and Shift-Return step, Command-G and Shift-Command-G too (from the
/// Edit menu), Escape closes.
struct TranscriptFindBar: View {
    @ObservedObject var find: TranscriptFindState
    /// The transcript's items, so the matches follow it as it streams.
    let items: [AgentItem]

    var body: some View {
        HStack(spacing: 6) {
            OctetTextField(placeholder: "Find in conversation", text: $find.query, label: "Find in conversation",
                           onSubmit: { find.step(1) }, focusRequest: find.focusRequest)
                .frame(width: 200)
                .onKeyPress(.return, phases: .down) { press in
                    guard press.modifiers.contains(.shift) else { return .ignored }
                    find.step(-1)
                    return .handled
                }
            if !find.query.isEmpty {
                Text(find.matches.isEmpty ? "No matches" : "\((find.index ?? 0) + 1) of \(find.matches.count)")
                    .font(Theme.captionFont.monospacedDigit())
                    .foregroundStyle(find.matches.isEmpty ? Theme.danger : Theme.textTertiary)
            }
            OctetIconButton(icon: "search.case", help: "Match case", active: find.caseSensitive) {
                find.caseSensitive.toggle()
            }
            OctetIconButton(icon: "chevron.up", help: "Previous match (⇧⌘G)") { find.step(-1) }
                .disabled(find.matches.isEmpty)
            OctetIconButton(icon: "chevron.down", help: "Next match (⌘G)") { find.step(1) }
                .disabled(find.matches.isEmpty)
            OctetIconButton(icon: "xmark", help: "Close (Esc)") { find.close() }
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 6)
        .octetGlass(cornerRadius: 10, fill: Theme.terminalBackground)
        .shadow(color: .black.opacity(0.3), radius: 8, y: 3)
        .onExitCommand { find.close() }
        .onAppear { find.refresh(items, restart: true) }
        .onChange(of: find.query) { _, _ in find.refresh(items, restart: true) }
        .onChange(of: find.caseSensitive) { _, _ in find.refresh(items, restart: true) }
        .onChange(of: items) { _, _ in find.refresh(items) }
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Find in conversation")
    }
}
