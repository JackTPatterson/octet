import Foundation
import SwiftUI

/// Keeps the usage ledger: notes what each conversation spends as it
/// spends it, and saves it beside the session server's other files.
@MainActor
final class UsageLedgerStore: ObservableObject {
    static let shared = UsageLedgerStore()

    @Published private(set) var ledger = UsageLedger()
    private var saving = false

    private static var url: URL {
        EngineSession.supportDirectory.appendingPathComponent("usage-ledger.json")
    }

    private init() {
        if let data = try? Data(contentsOf: Self.url), let saved = try? JSONDecoder().decode(UsageLedger.self, from: data) {
            ledger = saved
            ledger.prune()
        }
    }

    /// A conversation's running cost changed from `previous`.
    func noteCost(of session: AgentSession, from previous: Double?) {
        guard let growth = UsageLedger.growth(from: previous, to: session.conversation.costUSD) else { return }
        let conversation = session.conversation
        let fraction = conversation.contextUsed.flatMap { used in
            conversation.contextWindow.flatMap { $0 > 0 ? min(1, Double(used) / Double($0)) : nil }
        }
        ledger.record(UsageEntry(date: Date(), sessionId: session.id, title: session.title, agent: session.engine.agent,
                                 cwd: session.cwd, cost: growth, contextFraction: fraction))
        save()
    }

    private func save() {
        guard !saving else { return }
        saving = true
        // Coalesced: a burst of turns writes once.
        DispatchQueue.main.asyncAfter(deadline: .now() + 2) {
            MainActor.assumeIsolated {
                let store = UsageLedgerStore.shared
                store.saving = false
                guard let data = try? JSONEncoder().encode(store.ledger) else { return }
                DispatchQueue.global(qos: .utility).async {
                    try? FileManager.default.createDirectory(at: Self.url.deletingLastPathComponent(), withIntermediateDirectories: true)
                    try? data.write(to: Self.url, options: .atomic)
                }
            }
        }
    }
}

/// Where the usage went: conversations ranked by what they spent, over the
/// last five hours, day or week.
struct UsageBreakdownView: View {
    let close: () -> Void
    @EnvironmentObject private var window: WindowContext
    @ObservedObject private var store = UsageLedgerStore.shared
    @ObservedObject private var center = AgentCenter.shared
    @State private var period: UsageLedger.Period = .fiveHours

    var body: some View {
        let start = period.start()
        let rows = store.ledger.rows(since: start)
        let total = store.ledger.total(since: start)
        VStack(spacing: 0) {
            VStack(alignment: .leading, spacing: 10) {
                HStack {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Where your usage went").font(.system(size: 15, weight: .semibold)).foregroundStyle(Theme.textPrimary)
                        Text(rows.isEmpty ? "Nothing recorded in this period."
                             : "\(UsageLedger.money(total)) across \(Recap.count(rows.count, "conversation")), at API prices")
                            .font(Theme.uiFont).foregroundStyle(Theme.textTertiary)
                    }
                    Spacer()
                    OctetButton(title: "Done", kind: .secondary, compact: true, action: close).keyboardShortcut(.cancelAction)
                }
                Picker("Period", selection: $period) {
                    ForEach(UsageLedger.Period.allCases) { Text($0.title).tag($0) }
                }
                .labelsHidden()
                .pickerStyle(.segmented)
                .frame(width: 330)
            }
            .padding(16)
            Rectangle().fill(Theme.divider).frame(height: 1)
            if rows.isEmpty {
                empty
            } else {
                ScrollView {
                    VStack(spacing: 2) {
                        ForEach(rows) { row in
                            UsageRow(row: row, peak: rows.first?.cost ?? 1, session: center.sessions.first { $0.id == row.sessionId },
                                     open: { open(row) }, fresh: { startFresh(row) })
                        }
                    }
                    .padding(10)
                }
                .scrollIndicators(.hidden)
            }
            Rectangle().fill(Theme.divider).frame(height: 1)
            Text("Claude Code and OpenCode report what each conversation costs; Codex doesn't, so its conversations aren't here. On a subscription the cost is at API prices, so read it as each conversation's share of the allowance, not as money spent.")
                .font(Theme.captionFont).foregroundStyle(Theme.textTertiary)
                .fixedSize(horizontal: false, vertical: true)
                .padding(12)
        }
        .frame(width: 560, height: 520)
        .background(Theme.chrome)
    }

    private var empty: some View {
        VStack(spacing: 6) {
            OctetIcon("clock", size: 22).foregroundStyle(Theme.textTertiary)
            Text("Octet notes what each conversation spends from now on.")
                .font(Theme.uiFont).foregroundStyle(Theme.textTertiary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private func open(_ row: UsageLedger.Row) {
        guard let session = center.sessions.first(where: { $0.id == row.sessionId }) else { return }
        window.focusWorkspace(session.workspaceId)
        AgentCenter.shared.setActive(session.id, in: session.workspaceId)
        close()
    }

    private func startFresh(_ row: UsageLedger.Row) {
        guard let session = center.sessions.first(where: { $0.id == row.sessionId }) else { return }
        close()
        ConversationHandoff.continueConversation(session, in: session.engine, reason: .fresh, store: window.store)
    }
}

private struct UsageRow: View {
    let row: UsageLedger.Row
    let peak: Double
    let session: AgentSession?
    let open: () -> Void
    let fresh: () -> Void
    @State private var hovered = false

    var body: some View {
        let brand = AgentBrand.forAgent(row.agent)
        VStack(alignment: .leading, spacing: 5) {
            HStack(spacing: 8) {
                if let brand { AgentLogo(brand: brand, size: 13) }
                Text(row.title).font(Theme.uiFontMedium).foregroundStyle(Theme.textPrimary).lineLimit(1)
                Text(abbreviateHome(row.cwd)).font(Theme.captionFont).foregroundStyle(Theme.textTertiary)
                    .lineLimit(1).truncationMode(.head)
                Spacer(minLength: 6)
                Text(UsageLedger.money(row.cost)).font(Theme.uiFontMedium.monospacedDigit()).foregroundStyle(Theme.textPrimary)
            }
            GeometryReader { proxy in
                ZStack(alignment: .leading) {
                    Capsule().fill(Theme.card)
                    Capsule().fill(row.heavyContext ? Color.orange : Theme.accent)
                        .frame(width: max(4, proxy.size.width * min(1, row.cost / max(peak, 0.0001))))
                }
            }
            .frame(height: 4)
            HStack(spacing: 10) {
                Text("\(Recap.count(row.turns, "turn")) · \(UsageLedger.money(row.costPerTurn)) a turn")
                    .font(Theme.captionFont.monospacedDigit()).foregroundStyle(Theme.textTertiary)
                if row.heavyContext, let peak = row.peakContext {
                    Text("Context \(Int((peak * 100).rounded()))% full: every message re-reads it")
                        .font(Theme.captionFont).foregroundStyle(Color.orange).lineLimit(1)
                }
                Spacer(minLength: 4)
                if session != nil {
                    if row.heavyContext {
                        Button("Start Fresh", action: fresh).buttonStyle(.plain)
                            .font(Theme.captionFont.weight(.medium)).foregroundStyle(Theme.accent)
                            .help("A new conversation with a summary of this one")
                    }
                    Button("Open", action: open).buttonStyle(.plain)
                        .font(Theme.captionFont.weight(.medium)).foregroundStyle(Theme.accent)
                }
            }
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 8)
        .background(RoundedRectangle(cornerRadius: Theme.rowRadius + 2).fill(hovered ? Theme.hover : Theme.card.opacity(0.5)))
        .onHover { hovered = $0 }
        .accessibilityElement(children: .combine)
    }
}
