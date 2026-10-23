import AppKit
import SwiftUI

/// A command's whole output over the transcript, after T3 Code's command
/// output panel: numbered lines, search with next and previous, copy, and
/// following the end while the command still runs.
struct TranscriptOutputPanel: View {
    @ObservedObject var session: AgentSession
    let itemId: String
    let close: () -> Void
    @State private var query = ""
    @State private var current = 0
    @State private var following = true

    private var call: AgentToolCall? {
        guard let item = session.conversation.items.first(where: { $0.id == itemId }),
              case .tool(let call) = item.kind else { return nil }
        return call
    }

    var body: some View {
        let call = self.call
        let text = CommandOutputSearch.plain(call?.result ?? call?.liveOutput ?? "")
        let lines = text.components(separatedBy: "\n")
        let matches = CommandOutputSearch.matchingLines(lines, query: query)
        let running = call?.result == nil && session.conversation.isRunning
        ZStack {
            Theme.scrim
                .onTapGesture(perform: close)
                .accessibilityHidden(true)
            VStack(spacing: 0) {
                header(call: call, lines: lines, running: running)
                Rectangle().fill(Theme.divider).frame(height: 1)
                searchBar(matches: matches, text: text)
                Rectangle().fill(Theme.divider).frame(height: 1)
                output(lines: lines, matches: matches, running: running)
            }
            .frame(maxWidth: 980, maxHeight: 720)
            .octetGlass(cornerRadius: Theme.Radius.card, fill: Theme.terminalBackground)
            .padding(28)
        }
        .onExitCommand(perform: close)
        .onChange(of: query) { _, _ in current = 0 }
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Command output")
    }

    private func header(call: AgentToolCall?, lines: [String], running: Bool) -> some View {
        HStack(spacing: 8) {
            if let logo = call.flatMap({ LanguageLogo(mcpTool: $0.name, size: 14) }) { logo } else {
                OctetIcon(call?.iconName ?? "terminal", size: 14).foregroundStyle(Theme.textTertiary)
            }
            Text(call?.displayName ?? "Output").font(Theme.uiFontMedium).foregroundStyle(Theme.textPrimary)
            if let summary = call?.summary, !summary.isEmpty {
                ShellSummary(text: summary)
            }
            Spacer(minLength: 8)
            if running { LoadingLine(width: 14) }
            Text("\(lines.count) \(lines.count == 1 ? "line" : "lines")")
                .font(Theme.captionFont.monospacedDigit())
                .foregroundStyle(Theme.textTertiary)
            OctetIconButton(icon: "xmark", help: "Close (Esc)", action: close)
        }
        .padding(.horizontal, 12)
        .frame(height: 40)
    }

    private func searchBar(matches: [Int], text: String) -> some View {
        HStack(spacing: 6) {
            OctetTextField(placeholder: "Search output", text: $query, label: "Search output") { step(1, matches) }
                .frame(maxWidth: 320)
            if !query.isEmpty {
                Text(matches.isEmpty ? "No matches" : "\(min(current, matches.count - 1) + 1) of \(matches.count)")
                    .font(Theme.captionFont.monospacedDigit())
                    .foregroundStyle(matches.isEmpty ? Theme.danger : Theme.textTertiary)
            }
            OctetIconButton(icon: "chevron.up", help: "Previous match") { step(-1, matches) }
                .disabled(matches.isEmpty)
            OctetIconButton(icon: "chevron.down", help: "Next match") { step(1, matches) }
                .disabled(matches.isEmpty)
            Spacer(minLength: 4)
            OctetButton(title: "Copy", icon: "doc.on.doc", kind: .secondary, compact: true) {
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(text, forType: .string)
                ToastCenter.shared.info("Copied the output")
            }
            if !matches.isEmpty {
                OctetButton(title: "Copy Matches", kind: .ghost, compact: true) {
                    let lines = text.components(separatedBy: "\n")
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(matches.map { lines[$0] }.joined(separator: "\n"), forType: .string)
                    ToastCenter.shared.info("Copied \(matches.count) matching \(matches.count == 1 ? "line" : "lines")")
                }
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
    }

    private func step(_ by: Int, _ matches: [Int]) {
        guard !matches.isEmpty else { return }
        following = false
        current = (min(current, matches.count - 1) + by + matches.count) % matches.count
    }

    private func output(lines: [String], matches: [Int], running: Bool) -> some View {
        let matched = Set(matches)
        let focus = matches.isEmpty ? nil : matches[min(current, matches.count - 1)]
        let gutter = CGFloat(String(lines.count).count) * 7.5 + 14
        return ScrollViewReader { proxy in
            ScrollView([.vertical, .horizontal]) {
                LazyVStack(alignment: .leading, spacing: 0) {
                    ForEach(lines.indices, id: \.self) { index in
                        HStack(alignment: .top, spacing: 0) {
                            Text("\(index + 1)")
                                .font(Theme.monoFont.monospacedDigit())
                                .foregroundStyle(Theme.textTertiary)
                                .frame(width: gutter, alignment: .trailing)
                                .padding(.trailing, 10)
                            Text(highlighted(lines[index], match: matched.contains(index)))
                                .font(Theme.monoFont)
                                .foregroundStyle(Theme.textSecondary)
                                .fixedSize()
                        }
                        .padding(.vertical, 1)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .background(index == focus ? Theme.accent.opacity(0.22)
                                    : matched.contains(index) ? Theme.accent.opacity(0.08) : .clear)
                        .id(index)
                    }
                    Color.clear.frame(height: 1).id("end")
                }
                .padding(.vertical, 8)
                .padding(.trailing, 16)
                .textSelection(.enabled)
            }
            .octetScrollIndicators()
            .onAppear { if following { proxy.scrollTo("end", anchor: .bottom) } }
            .onChange(of: focus) { _, focus in
                guard let focus else { return }
                withAnimation(.easeOut(duration: 0.15)) { proxy.scrollTo(focus, anchor: .center) }
            }
            .onChange(of: lines.count) { _, _ in
                if running && following { proxy.scrollTo("end", anchor: .bottom) }
            }
        }
    }

    /// The line with each occurrence of the search marked.
    private func highlighted(_ line: String, match: Bool) -> AttributedString {
        var text = AttributedString(line)
        let needle = query.trimmingCharacters(in: .whitespaces)
        guard match, !needle.isEmpty else { return text }
        var search = text.startIndex
        while search < text.endIndex,
              let range = text[search...].range(of: needle, options: [.caseInsensitive, .diacriticInsensitive]) {
            text[range].foregroundColor = Theme.textPrimary
            text[range].backgroundColor = Theme.accent.opacity(0.45)
            search = range.upperBound
        }
        return text
    }
}

/// The command, one line, in the header.
private struct ShellSummary: View {
    let text: String
    var body: some View {
        Text(text)
            .font(Theme.monoFont)
            .foregroundStyle(Theme.textTertiary)
            .lineLimit(1)
            .truncationMode(.middle)
    }
}
