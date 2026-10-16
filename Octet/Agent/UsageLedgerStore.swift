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
