import SwiftUI

struct ProjectJobsView: View {
    let root: String
    @Environment(\.dismiss) private var dismiss
    @ObservedObject private var center = ProjectJobCenter.shared
    @State private var editing: ProjectJob?
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text("Scheduled project jobs").font(.headline)
                Spacer()
                Button("New job") { editing = ProjectJob(root: root, name: "", prompt: "", provider: "claude", cron: "0 9 * * 1-5", timeZone: TimeZone.current.identifier, nextRun: Date()) }
                Button("Done") { dismiss() }
            }
            Text("Uses Check-ins' timer and global pause. Runs while Octet is open; missed occurrences collapse into one on return.")
                .font(Theme.captionFont).foregroundStyle(Theme.textSecondary)
            if let failure = center.failure { Text(failure).foregroundStyle(.red).textSelection(.enabled) }
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    ForEach(center.jobs.filter { $0.root == root }) { job in
                        VStack(alignment: .leading, spacing: 6) {
                            Text(job.name).font(Theme.uiFontMedium)
                            Text("\(job.cron) · \(job.timeZone) · \(job.provider)").font(Theme.captionFont)
                            Text(job.enabled ? "Next: \(job.nextRun.formatted())" : "Paused").font(Theme.captionFont)
                            HStack {
                                Button(job.enabled ? "Pause" : "Enable") { center.toggle(job.id) }
                                Button("Run now") { center.run(job.id) }
                                Button("Edit") { editing = job }
                                Button("Delete", role: .destructive) { center.remove(job.id) }
                            }
                            ForEach(center.runs.filter { $0.jobId == job.id }.suffix(8).reversed()) { run in
                                VStack(alignment: .leading, spacing: 3) {
                                    Text("\(run.started.formatted()) · \(run.status.rawValue)").font(Theme.captionFont)
                                    Text(run.detail).font(Theme.captionFont).foregroundStyle(Theme.textSecondary).textSelection(.enabled)
                                    if let checkout = run.checkout { Text(checkout).font(Theme.captionFont).textSelection(.enabled) }
                                    if run.active {
                                        Button("End tracking…") {
                                            ConfirmCenter.shared.ask(title: "End tracking this run?", message: "This does not stop the agent. Confirm only after inspecting its workspace; the schedule will be paused until you enable it again.", confirmTitle: "End tracking") { _ in center.acknowledge(run.id) }
                                        }
                                    }
                                }.padding(8).background(Theme.card)
                            }
                        }
                        Divider()
                    }
                    if !center.jobs.contains(where: { $0.root == root }) { Text("No jobs for this project.").foregroundStyle(Theme.textSecondary) }
                }
            }
        }.padding(20).frame(width: 650, height: 560).foregroundStyle(Theme.textPrimary).background(Theme.chrome)
            .sheet(item: $editing) { job in ProjectJobEditor(job: job) { editing = nil } }
    }
}

private struct ProjectJobEditor: View {
    @State var job: ProjectJob
    let close: () -> Void
    @State private var error: String?
    @State private var saving = false
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Project job").font(.headline)
            field("Name", text: $job.name)
            Text("Agent prompt").font(Theme.captionFont)
            TextEditor(text: $job.prompt).scrollContentBackground(.hidden).padding(6).background(Theme.cardSelected).frame(height: 110)
            Picker("Agent", selection: $job.provider) { Text("Claude Code").tag("claude"); Text("Codex").tag("codex") }
            HStack {
                field("Cron: minute hour day month weekday", text: $job.cron)
                Menu("Presets") {
                    Button("Hourly") { job.cron = "0 * * * *" }
                    Button("Daily at 9") { job.cron = "0 9 * * *" }
                    Button("Weekdays at 9") { job.cron = "0 9 * * 1-5" }
                    Button("Monday at 9") { job.cron = "0 9 * * 1" }
                }
            }
            field("Timezone", text: $job.timeZone)
            Toggle("Create a fresh worktree for each run", isOn: $job.freshWorktree)
            field("Optional precheck shell command (exit 0 continues)", text: $job.precheck)
            Stepper("Precheck timeout: \(job.precheckTimeout) seconds", value: $job.precheckTimeout, in: 1...3600)
            Toggle("Enabled", isOn: $job.enabled)
            Text("Saving authorizes the precheck and agent prompt on this schedule. Setup uses the project's existing approval policy. Active runs never overlap for the same job.")
                .font(Theme.captionFont).foregroundStyle(Theme.textSecondary)
            if let error { Text(error).foregroundStyle(.red) }
            HStack {
                Spacer(); Button("Cancel", action: close)
                Button(saving ? "Saving…" : "Save schedule") {
                    saving = true
                    let draft = job
                    Task {
                        do {
                            var saved = draft
                            try saved.validate()
                            saved.nextRun = try await Task.detached { try draft.next(after: Date()) }.value
                            try ProjectJobCenter.shared.upsert(saved)
                            close()
                        } catch { self.error = error.localizedDescription; saving = false }
                    }
                }.disabled(saving)
            }
        }.padding(20).frame(width: 580).foregroundStyle(Theme.textPrimary).background(Theme.chrome)
    }
    private func field(_ title: String, text: Binding<String>) -> some View {
        TextField(title, text: text).textFieldStyle(.plain).padding(8).background(Theme.cardSelected)
            .clipShape(RoundedRectangle(cornerRadius: 5))
    }

}
