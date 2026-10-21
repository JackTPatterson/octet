import SwiftUI

/// A project's scheduled jobs, in a sheet from the panel strip's calendar
/// button: each job with its schedule in words, its next run and its recent
/// runs, and a way to pause, run, edit or delete it.
struct ProjectJobsView: View {
    let root: String
    @Environment(\.dismiss) private var dismiss
    @ObservedObject private var center = ProjectJobCenter.shared
    @State private var editing: ProjectJob?

    private var jobs: [ProjectJob] { center.jobs.filter { $0.root == root } }

    var body: some View {
        VStack(alignment: .leading, spacing: Theme.Space.lg) {
            HStack(spacing: Theme.Space.md) {
                VStack(alignment: .leading, spacing: Theme.Space.xxs) {
                    Text("Scheduled jobs").font(Theme.Text.title3).foregroundStyle(Theme.textPrimary)
                    Text((root as NSString).lastPathComponent)
                        .font(Theme.Text.caption).foregroundStyle(Theme.textTertiary)
                }
                Spacer()
                OctetButton(title: "New Job", icon: "plus", kind: .secondary, compact: true) {
                    editing = ProjectJob(root: root, name: "", prompt: "", provider: "claude", cron: "0 9 * * 1-5",
                                         timeZone: TimeZone.current.identifier, nextRun: Date())
                }
                OctetButton(title: "Done", kind: .primary, compact: true) { dismiss() }
                    .keyboardShortcut(.defaultAction)
            }
            Text("Jobs use Check-ins' timer and its global pause. They run while Octet is open; runs missed while it was closed collapse into one when it opens.")
                .font(Theme.Text.caption).foregroundStyle(Theme.textSecondary)
                .fixedSize(horizontal: false, vertical: true)
            if let failure = center.failure {
                Text(failure)
                    .font(Theme.Text.caption).foregroundStyle(Theme.danger)
                    .textSelection(.enabled)
            }
            if jobs.isEmpty {
                OctetEmptyState(icon: "clock", title: "No jobs for this project",
                                message: "A job runs an agent prompt here on a schedule, such as a dependency check every weekday morning.",
                                actionTitle: "New Job", actionIcon: "plus") {
                    editing = ProjectJob(root: root, name: "", prompt: "", provider: "claude", cron: "0 9 * * 1-5",
                                         timeZone: TimeZone.current.identifier, nextRun: Date())
                }
            } else {
                ScrollView {
                    VStack(alignment: .leading, spacing: Theme.Space.md) {
                        ForEach(jobs) { job in
                            ProjectJobCard(job: job, center: center) { editing = job }
                        }
                    }
                }
                .octetScrollIndicators()
            }
        }
        .padding(Theme.Space.xl + 4)
        .frame(width: 650, height: 560, alignment: .top)
        .background(Theme.chrome)
        .environment(\.colorScheme, Theme.colorScheme)
        .hostsOctetDialogs()
        .sheet(item: $editing) { job in ProjectJobEditor(job: job) { editing = nil } }
    }
}

/// One job: its name and schedule, what it does next, the controls, and
/// its last few runs.
private struct ProjectJobCard: View {
    let job: ProjectJob
    @ObservedObject var center: ProjectJobCenter
    let edit: () -> Void

    private var runs: [ProjectJobRun] { Array(center.runs.filter { $0.jobId == job.id }.suffix(8).reversed()) }

    var body: some View {
        VStack(alignment: .leading, spacing: Theme.Space.md) {
            HStack(alignment: .firstTextBaseline, spacing: Theme.Space.md) {
                VStack(alignment: .leading, spacing: Theme.Space.xxs) {
                    Text(job.name).font(Theme.Text.bodyMedium).foregroundStyle(Theme.textPrimary)
                    Text(scheduleLine).font(Theme.Text.caption).foregroundStyle(Theme.textSecondary)
                        .help(job.cron)
                    Text(job.enabled ? "Next run \(job.nextRun.formatted(date: .abbreviated, time: .shortened))" : "Paused")
                        .font(Theme.Text.caption)
                        .foregroundStyle(job.enabled ? Theme.textTertiary : Theme.warning)
                }
                Spacer(minLength: Theme.Space.md)
                OctetButton(title: job.enabled ? "Pause" : "Resume", icon: job.enabled ? "pause.circle" : "play.circle",
                            kind: .ghost, compact: true) { center.toggle(job.id) }
                OctetButton(title: "Run Now", icon: "play", kind: .secondary, compact: true) { center.run(job.id) }
                OctetIconButton(icon: "pencil", help: "Edit \(job.name)", action: edit)
                OctetIconButton(icon: "trash", help: "Delete \(job.name)", tint: Theme.danger) { confirmDelete() }
            }
            if !runs.isEmpty {
                VStack(alignment: .leading, spacing: Theme.Space.xs) {
                    ForEach(runs) { run in ProjectJobRunRow(run: run, center: center) }
                }
            }
        }
        .padding(Theme.Space.lg)
        .background(RoundedRectangle(cornerRadius: Theme.Radius.card).fill(Theme.card))
        .overlay(RoundedRectangle(cornerRadius: Theme.Radius.card).strokeBorder(Theme.border, lineWidth: 1))
        .accessibilityElement(children: .contain)
    }

    /// The schedule in words when it has a common shape, with the zone and
    /// the agent; the raw cron is in the tooltip.
    private var scheduleLine: String {
        let when = CronDescription.describe(job.cron) ?? job.cron
        let agent = job.provider == "codex" ? "Codex" : "Claude Code"
        let zone = job.timeZone == TimeZone.current.identifier ? nil : job.timeZone
        return ([when, zone, agent].compactMap { $0 }).joined(separator: " · ")
    }

    private func confirmDelete() {
        ConfirmCenter.shared.ask(
            title: "Delete “\(job.name)”?",
            message: "Its schedule and run history are removed. Runs already started keep going.",
            confirmTitle: "Delete Job", destructive: true
        ) { _ in center.remove(job.id) }
    }
}

private struct ProjectJobRunRow: View {
    let run: ProjectJobRun
    @ObservedObject var center: ProjectJobCenter

    private var tone: Color {
        switch run.status {
        case .completed: Theme.success
        case .failed, .interrupted: Theme.danger
        case .skipped: Theme.textTertiary
        case .preparing, .setup, .running: Theme.warning
        }
    }

    var body: some View {
        HStack(alignment: .top, spacing: Theme.Space.md) {
            Circle().fill(tone).frame(width: 6, height: 6).padding(.top, 5).accessibilityHidden(true)
            VStack(alignment: .leading, spacing: Theme.Space.xxs) {
                Text("\(run.started.formatted(date: .abbreviated, time: .shortened)) · \(run.status.rawValue.capitalized)")
                    .font(Theme.Text.captionMedium).foregroundStyle(Theme.textSecondary)
                if !run.detail.isEmpty {
                    Text(run.detail).font(Theme.Text.caption).foregroundStyle(Theme.textTertiary)
                        .textSelection(.enabled)
                        .fixedSize(horizontal: false, vertical: true)
                }
                if let checkout = run.checkout {
                    Text(checkout).font(Theme.Text.mono(10.5)).foregroundStyle(Theme.textTertiary)
                        .textSelection(.enabled).lineLimit(1).truncationMode(.middle)
                }
            }
            Spacer(minLength: 0)
            if run.active {
                OctetButton(title: "End Tracking…", kind: .ghost, compact: true) {
                    ConfirmCenter.shared.ask(
                        title: "End tracking this run?",
                        message: "This doesn't stop the agent. Confirm only after looking at its workspace; the schedule stays paused until you resume it.",
                        confirmTitle: "End Tracking"
                    ) { _ in center.acknowledge(run.id) }
                }
            }
        }
        .padding(.horizontal, Theme.Space.md)
        .padding(.vertical, Theme.Space.sm)
        .background(RoundedRectangle(cornerRadius: Theme.Radius.lg).fill(Theme.terminalBackground.opacity(0.5)))
        .accessibilityElement(children: .combine)
    }
}

private struct ProjectJobEditor: View {
    @State var job: ProjectJob
    let close: () -> Void
    @State private var error: String?
    @State private var saving = false

    private static let presets: [(title: String, cron: String)] = [
        ("Hourly", "0 * * * *"), ("Every day at 9:00", "0 9 * * *"),
        ("Weekdays at 9:00", "0 9 * * 1-5"), ("Mondays at 9:00", "0 9 * * 1"),
    ]

    /// The schedule as it'll be read back, or why it won't parse.
    private var scheduleCheck: (text: String, valid: Bool) {
        do {
            _ = try CronSchedule(job.cron, timeZone: job.timeZone)
            return (CronDescription.describe(job.cron) ?? "Custom schedule", true)
        } catch {
            return (error.localizedDescription, false)
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: Theme.Space.lg) {
            Text(job.name.isEmpty ? "New job" : job.name).font(Theme.Text.title3).foregroundStyle(Theme.textPrimary)
            labelled("Name") { OctetTextField(placeholder: "Dependency check", text: $job.name, label: "Name") }
            labelled("Agent prompt") {
                OctetTextEditor(placeholder: "What the agent should do each run", text: $job.prompt, minHeight: 96, maxHeight: 140)
            }
            labelled("Agent") {
                OctetSelect(selection: $job.provider, options: [("claude", "Claude Code"), ("codex", "Codex")], width: 180)
            }
            labelled("Schedule") {
                VStack(alignment: .leading, spacing: Theme.Space.sm) {
                    HStack(spacing: Theme.Space.sm) {
                        ForEach(Self.presets, id: \.cron) { preset in
                            OctetButton(title: preset.title, kind: job.cron == preset.cron ? .secondary : .ghost,
                                        compact: true) { job.cron = preset.cron }
                        }
                    }
                    OctetTextField(placeholder: "minute hour day month weekday", text: $job.cron,
                                   label: "Cron expression", invalid: !scheduleCheck.valid)
                    Text(scheduleCheck.text)
                        .font(Theme.Text.caption)
                        .foregroundStyle(scheduleCheck.valid ? Theme.textSecondary : Theme.danger)
                }
            }
            labelled("Time zone") { OctetTextField(placeholder: TimeZone.current.identifier, text: $job.timeZone, label: "Time zone") }
            Toggle("Create a fresh worktree for each run", isOn: $job.freshWorktree).toggleStyle(OctetCheckboxStyle())
            labelled("Precheck") {
                VStack(alignment: .leading, spacing: Theme.Space.sm) {
                    OctetTextField(placeholder: "Optional shell command; exit 0 runs the job", text: $job.precheck, label: "Precheck command")
                    HStack(spacing: Theme.Space.md) {
                        Text("Timeout").font(Theme.Text.caption).foregroundStyle(Theme.textSecondary)
                        OctetNumberField(label: "Precheck timeout", value: timeout, range: 1...3600, unit: "s")
                    }
                }
            }
            Toggle("Enabled", isOn: $job.enabled).toggleStyle(OctetCheckboxStyle())
            Text("Saving lets the precheck and the agent prompt run on this schedule, under the project's existing approval policy. Runs of the same job never overlap.")
                .font(Theme.Text.caption).foregroundStyle(Theme.textSecondary)
                .fixedSize(horizontal: false, vertical: true)
            if let error {
                Text(error).font(Theme.Text.caption).foregroundStyle(Theme.danger).textSelection(.enabled)
            }
            HStack(spacing: Theme.Space.md) {
                Spacer()
                OctetButton(title: "Cancel", kind: .secondary, action: close)
                    .keyboardShortcut(.cancelAction)
                OctetButton(title: saving ? "Saving…" : "Save Schedule", kind: .primary) { save() }
                    .keyboardShortcut(.defaultAction)
                    .disabled(saving)
            }
        }
        .padding(Theme.Space.xl + 4)
        .frame(width: 580)
        .background(Theme.chrome)
        .environment(\.colorScheme, Theme.colorScheme)
        .hostsOctetDialogs()
    }

    private var timeout: Binding<Double> {
        Binding(get: { Double(job.precheckTimeout) }, set: { job.precheckTimeout = Int($0) })
    }

    private func save() {
        saving = true
        let draft = job
        Task {
            do {
                var saved = draft
                try saved.validate()
                saved.nextRun = try await Task.detached { try draft.next(after: Date()) }.value
                try ProjectJobCenter.shared.upsert(saved)
                close()
            } catch {
                self.error = error.localizedDescription
                saving = false
            }
        }
    }

    private func labelled<Content: View>(_ title: String, @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: Theme.Space.xs) {
            Text(title).font(Theme.Text.captionMedium).foregroundStyle(Theme.textSecondary)
            content()
        }
    }
}
