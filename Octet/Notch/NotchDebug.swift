import AppKit
import os

#if DEBUG
@MainActor
enum NotchMetrics {
    static let log = OSLog(subsystem: "com.jpxsoftware.octet.notch", category: .pointsOfInterest)
    static let began = CFAbsoluteTimeGetCurrent()
    static var recomputes = 0
    static var publications = 0
    static var expandMS: [Double] = []
    static var refreshMS = 0.0

    static func expanded(in milliseconds: Double) {
        if expandMS.count == 64 { expandMS.removeFirst() }
        expandMS.append(milliseconds)
    }
    static func dump(monitors: Int, timers: Int, subscriptions: Int, sample: Bool) {
        guard let dir = ProcessInfo.processInfo.environment["OCTET_SNAPSHOT_DIR"] else { return }
        let elapsed = max(0.001, CFAbsoluteTimeGetCurrent() - began)
        let text = "sample=\(sample) observationSeconds=\(elapsed) recomputes=\(recomputes) "
            + "recomputesPerMinute=\(Double(recomputes) * 60 / elapsed) publications=\(publications) "
            + "refreshMainMS=\(refreshMS) expandHandlerMainMS=\(expandMS) monitors=\(monitors) "
            + "pendingOneShots=\(timers) modelSubscriptions=\(subscriptions)\n"
        try? text.write(toFile: dir + "/notch-performance.txt", atomically: true, encoding: .utf8)
    }
}

/// Made-up agents, work and allowances for the verification hooks. Nothing
/// here is read from, or acted on in, a real session.
enum NotchSample {
    static var snapshot: NotchSnapshot {
        let now = Date()
        var sample = NotchSnapshot()
        sample.agents = NotchAgentOrdering.sorted([
            NotchAgentRow(id: "s1", vendor: "claude", title: "Review auth flow", workspace: "api-server",
                          detail: "Wants to run: npm test -- auth", status: .needsInput, since: now.addingTimeInterval(-95),
                          canStop: false, canReply: true),
            NotchAgentRow(id: "s2", vendor: "claude", title: "Migrate schema", workspace: "billing",
                          detail: "Editing db/migrations/0042_invoices.sql", status: .working, since: now.addingTimeInterval(-262),
                          canStop: true, canReply: false),
            NotchAgentRow(id: "s3", vendor: "codex", title: "Fix flaky upload test", workspace: "web",
                          detail: "Running the suite again", status: .working, since: now.addingTimeInterval(-41),
                          canStop: true, canReply: false),
            NotchAgentRow(id: "s4", vendor: "claude", title: "Write release notes", workspace: "octet",
                          detail: "Done. Drafted notes for beta 21.", status: .done, since: now.addingTimeInterval(-600)),
            NotchAgentRow(id: "s5", vendor: "codex", title: "Bump dependencies", workspace: "docs",
                          detail: "Done. 14 packages updated.", status: .done, since: now.addingTimeInterval(-3_000)),
        ])
        sample.runtimes = [
            NotchRuntimeRow(id: "r1", kind: "Task", title: "npm run dev", since: now.addingTimeInterval(-1_240)),
            NotchRuntimeRow(id: "r2", kind: "Monitor", title: "tail -f logs/app.log", since: now.addingTimeInterval(-380)),
            NotchRuntimeRow(id: "r3", kind: "Subagent", title: "Explore the payments module", since: now.addingTimeInterval(-52)),
        ]
        sample.readyWaits = [
            NotchWaitRow(id: "w1", title: "PR #482 merged", next: "Rebase the billing branch and rerun the migration check.",
                         readyAt: now.addingTimeInterval(-300)),
        ]
        sample.waitingCount = 2
        sample.checkIns = [
            NotchCheckInRow(id: "c1", title: "Check the nightly build", due: true, nextAt: now, canSkip: true, schedule: "Every day at 9:00 AM"),
            NotchCheckInRow(id: "c2", title: "Review open PRs", due: false, nextAt: now.addingTimeInterval(86_400 * 2), canSkip: true,
                            schedule: "Every Monday"),
        ]
        sample.usage = [
            NotchUsageRow(agent: "claude", name: "Claude", plan: "Max", note: nil, windows: [
                .init(name: "5h", title: "5-hour limit", used: 0.38, resetsAt: now.addingTimeInterval(2 * 3600 + 600)),
                .init(name: "7d", title: "Weekly limit", used: 0.74, resetsAt: now.addingTimeInterval(3 * 86_400 + 4 * 3600)),
            ], updatedAt: now),
            NotchUsageRow(agent: "codex", name: "Codex", plan: "Codex", note: nil, windows: [
                .init(name: "5h", title: "5-hour limit", used: 0.92, resetsAt: now.addingTimeInterval(55 * 60)),
            ], updatedAt: now),
        ]
        sample.folders = ["/Users/sample/Developer/apps/octet", "/Users/sample/Developer/api-server",
                          "/Users/sample/Developer/web", "/Users/sample/Developer/docs"].map { NotchFolder(path: $0) }
        return sample
    }

    static var peek: NotchPeek {
        NotchPeek(kind: .needsInput, agent: "claude", line: "Review auth flow needs you", more: 1)
    }
}

/// OCTET_OPEN_WINDOW hooks: "notch" opens the island over sample data,
/// "notch:collapsed" leaves it collapsed with sample glyphs, "notch:peek"
/// shows a peek, and "notch:tab=<agents|now|usage|actions>" picks the page.
/// "notch:compact" uses the compact size.
@MainActor
enum NotchDebug {
    private static var claimed = false

    static func runHook() {
        guard let open = ProcessInfo.processInfo.environment["OCTET_OPEN_WINDOW"], open == "notch" || open.hasPrefix("notch:"),
              !claimed else { return }
        // Every restored window runs the hooks; the notch is the app's, once.
        claimed = true
        let parts = open.split(separator: ":").dropFirst().map(String.init)
        let tab = parts.compactMap { $0.hasPrefix("tab=") ? NotchTab(rawValue: String($0.dropFirst(4))) : nil }.first
        let phase: NotchMachine.Phase = parts.contains("collapsed") ? .collapsed : parts.contains("peek") ? .peek : .expanded
        let size: NotchSettings.Size = parts.contains("compact") ? .compact : .regular
        DispatchQueue.main.asyncAfter(deadline: .now() + 3) {
            NotchController.shared.debugShow(phase: phase, tab: tab, size: size)
        }
    }
}
#endif
