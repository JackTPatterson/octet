import AppKit
import SwiftUI

// MARK: - The composer

/// A check-in being written in the sheet: when, how often, until when, what
/// to say then, what to do about it, and where it comes back to.
struct CheckInDraft: Identifiable {
    enum Repeat: String, CaseIterable, Identifiable {
        case once, every, daily, weekly
        var id: String { rawValue }
        var title: String {
            switch self {
            case .once: "Don't repeat"
            case .every: "Every few hours, days or weeks"
            case .daily: "Every day"
            case .weekly: "Every week"
            }
        }
    }

    enum Stop: String, CaseIterable, Identifiable {
        case never, date, count
        var id: String { rawValue }
        var title: String {
            switch self {
            case .never: "Until I cancel"
            case .date: "Until a date"
            case .count: "A number of times"
            }
        }
    }

    let id = UUID()
    var origin: Wait.Origin
    /// The window that asked, which shows the sheet.
    var windowId: UUID?
    /// Set when changing an existing check-in.
    var editingId: String?
    var title = ""
    var prompt = ""
    var mode: CheckInMode = .both
    var first: Date = CheckInDraft.morning(daysAhead: 1)
    var repeats: Repeat = .once
    var every = 1
    var unit: CheckInRecurrence.Unit = .days
    var minuteOfDay = 9 * 60
    var weekday = 2
    var stop: Stop = .never
    var stopDate: Date = CheckInDraft.morning(daysAhead: 30)
    var stopCount = 10
    /// Open straight on the time picker.
    var startPicking = false

    init(origin: Wait.Origin, windowId: UUID? = nil, mode: CheckInMode = .both) {
        self.origin = origin
        self.windowId = windowId
        self.mode = mode
    }

    init(editing wait: Wait, windowId: UUID?) {
        origin = wait.origin
        self.windowId = windowId
        editingId = wait.id
        title = wait.title
        prompt = wait.next
        first = wait.nextCheckAt
        if let info = wait.checkIn {
            mode = info.mode
            if let rule = info.recurrence {
                switch rule.kind {
                case .every:
                    repeats = .every
                    every = rule.every
                    unit = rule.unit
                case .daily:
                    repeats = .daily
                    minuteOfDay = rule.hour * 60 + rule.minute
                case .weekly:
                    repeats = .weekly
                    minuteOfDay = rule.hour * 60 + rule.minute
                    weekday = rule.weekday
                }
                if let until = rule.until {
                    stop = .date
                    stopDate = until
                } else if let count = rule.count {
                    stop = .count
                    stopCount = count
                }
            }
        }
    }

    static func morning(daysAhead days: Int, now: Date = Date(), calendar: Calendar = .current) -> Date {
        calendar.date(byAdding: .day, value: days, to: now).flatMap { calendar.date(bySettingHour: 9, minute: 0, second: 0, of: $0) }
            ?? now.addingTimeInterval(Double(days) * 86_400)
    }

    mutating func setFirst(_ date: Date) {
        first = date
    }

    /// A name from the first line of the prompt.
    static func defaultTitle(prompt: String) -> String {
        let line = prompt.split(whereSeparator: \.isNewline).first.map(String.init) ?? ""
        let trimmed = line.trimmingCharacters(in: .whitespaces)
        return trimmed.isEmpty ? "Check-in" : HandoffBrief.clip(trimmed, 48)
    }

    /// Longer waits than a snooze offers.
    static func longHaulPresets(now: Date, calendar: Calendar) -> [CustomSnooze.Preset] {
        [(3, "In 3 Days", "3d"), (7, "In a Week", "1w"), (14, "In 2 Weeks", "2w"), (30, "In a Month", "1m")].compactMap { days, title, id in
            calendar.date(byAdding: .day, value: days, to: now)
                .flatMap { calendar.date(bySettingHour: 9, minute: 0, second: 0, of: $0) }
                .map { CustomSnooze.Preset(id: "long-" + id, title: title, date: $0) }
        }
    }

    private var stopsAt: Date? { repeats != .once && stop == .date ? stopDate : nil }
    private var stopsAfter: Int? { repeats != .once && stop == .count ? stopCount : nil }

    /// The first time it comes round: the chosen time, or for a daily or
    /// weekly one, the next time that fits.
    func firstDate(now: Date = Date(), calendar: Calendar = .current) -> Date? {
        switch repeats {
        case .once, .every: return first
        case .daily, .weekly: return recurrence(first: first, now: now, calendar: calendar)?.start
        }
    }

    func recurrence(first: Date, now: Date = Date(), calendar: Calendar = .current) -> CheckInRecurrence? {
        let hour = minuteOfDay / 60, minute = minuteOfDay % 60
        switch repeats {
        case .once: return nil
        case .every: return .every(every, unit, startingAt: first, until: stopsAt, count: stopsAfter)
        case .daily: return .daily(hour: hour, minute: minute, after: now, calendar: calendar, until: stopsAt, count: stopsAfter)
        case .weekly:
            return .weekly(weekday: weekday, hour: hour, minute: minute, after: now, calendar: calendar,
                           until: stopsAt, count: stopsAfter)
        }
    }

    func problem(now: Date = Date()) -> String? {
        if prompt.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { return "Write what to say when it comes round." }
        if (repeats == .once || repeats == .every), first.timeIntervalSince(now) < 30 { return "Pick a time in the future." }
        if repeats == .every, unit == .hours, every < 1 { return "Check-ins come at most once an hour." }
        if let stopsAt, let start = firstDate(now: now), stopsAt <= start { return "The end date is before the first check-in." }
        return nil
    }

    var canSave: Bool { problem() == nil }

    /// "Every 2 days, until Dec 1".
    func summary(now: Date = Date()) -> String {
        guard let start = firstDate(now: now) else { return "" }
        let when = "First " + CheckInInfo.dayTime(start)
        guard let rule = recurrence(first: start, now: now) else { return when }
        return when + " · " + rule.summary
    }
}

/// The sheet for a new check-in, or for changing one.
struct CheckInEditorSheet: View {
    @State var draft: CheckInDraft
    let close: () -> Void
    @State private var picking: Pick?
    @ObservedObject private var center = CheckInCenter.shared

    enum Pick { case first, stop }

    init(draft: CheckInDraft, close: @escaping () -> Void) {
        _draft = State(initialValue: draft)
        _picking = State(initialValue: draft.startPicking ? .first : nil)
        self.close = close
    }

    var body: some View {
        Group {
            if let picking {
                SnoozePickerDialog(
                    label: "", heading: picking == .first ? "When should it first come round?" : "When should it stop?",
                    blurb: picking == .first ? "Octet reminds you then, and can wake the agent."
                        : "No check-ins after this day.",
                    confirmTitle: "Use This Time", resultPrefix: "", extraPresets: CheckInDraft.longHaulPresets
                ) { date in
                    if let date {
                        if picking == .first { draft.setFirst(date) } else { draft.stopDate = date }
                    }
                    self.picking = nil
                }
                .padding(20)
                .frame(maxWidth: .infinity)
            } else {
                form
            }
        }
        .frame(width: 480)
        .background(Theme.chrome)
    }

    private var form: some View {
        VStack(alignment: .leading, spacing: 0) {
            VStack(alignment: .leading, spacing: 3) {
                Text(draft.editingId == nil ? "Check back later" : "Change check-in")
                    .font(Theme.interfaceFont(15, weight: .semibold)).foregroundStyle(Theme.textPrimary)
                Text("For work that takes days or weeks to give a result. Octet brings it back at the right time, even if the session has ended or Octet was closed.")
                    .font(Theme.uiFont).foregroundStyle(Theme.textTertiary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .padding(16)
            Rectangle().fill(Theme.divider).frame(height: 1)
            VStack(alignment: .leading, spacing: 12) {
                whenFields
                repeatFields
                promptFields
                modeFields
                field("Name") {
                    OctetTextField(placeholder: CheckInDraft.defaultTitle(prompt: draft.prompt), text: $draft.title)
                }
                Text("Comes back to " + place)
                    .font(Theme.captionFont).foregroundStyle(Theme.textTertiary)
                Text(draft.problem() ?? draft.summary())
                    .font(Theme.captionFont)
                    .foregroundStyle(draft.problem() == nil ? Theme.textSecondary : Theme.danger)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .padding(16)
            Rectangle().fill(Theme.divider).frame(height: 1)
            HStack {
                Spacer()
                OctetButton(title: "Cancel", kind: .secondary, compact: true, action: close).keyboardShortcut(.cancelAction)
                OctetButton(title: draft.editingId == nil ? "Set Check-in" : "Save", kind: .primary, compact: true, action: save)
                    .keyboardShortcut(.defaultAction)
                    .disabled(!draft.canSave)
            }
            .padding(12)
        }
    }

    private var place: String {
        var place = draft.origin.workspaceLabel ?? HandoffBrief.abbreviate(draft.origin.cwd)
        if let branch = draft.origin.branch { place += " on \(branch)" }
        if let agent = draft.origin.agent { place += " · " + (AgentBrand.forAgent(agent)?.displayName ?? agent) }
        return place
    }

    @ViewBuilder private var whenFields: some View {
        if draft.repeats == .daily || draft.repeats == .weekly {
            EmptyView()
        } else {
            field("First check") {
                VStack(alignment: .leading, spacing: 6) {
                    Text(CheckInInfo.dayTime(draft.first)).font(Theme.uiFont).foregroundStyle(Theme.textPrimary)
                    HStack(spacing: 6) {
                        OctetButton(title: "Tomorrow", kind: .secondary, compact: true) { draft.setFirst(CheckInDraft.morning(daysAhead: 1)) }
                        OctetButton(title: "In 3 days", kind: .secondary, compact: true) { draft.setFirst(CheckInDraft.morning(daysAhead: 3)) }
                        OctetButton(title: "Next week", kind: .secondary, compact: true) { draft.setFirst(CheckInDraft.morning(daysAhead: 7)) }
                        OctetButton(title: "Pick a Time…", kind: .secondary, compact: true) { picking = .first }
                    }
                    .fixedSize()
                }
            }
        }
    }

    @ViewBuilder private var repeatFields: some View {
        field("Repeat") {
            OctetSelect(selection: $draft.repeats, options: CheckInDraft.Repeat.allCases.map { ($0, $0.title) }, width: 250)
                .accessibilityLabel("Repeat")
        }
        switch draft.repeats {
        case .once:
            EmptyView()
        case .every:
            field("Every") {
                HStack(spacing: 8) {
                    OctetNumberField(label: "Every", value: Binding(get: { Double(draft.every) }, set: { draft.every = Int($0) }),
                                     range: 1...365, width: 110)
                    OctetSelect(selection: $draft.unit,
                                options: CheckInRecurrence.Unit.allCases.map { ($0, $0.title) }, width: 110)
                        .accessibilityLabel("Unit")
                }
            }
        case .daily, .weekly:
            field("At") {
                HStack(spacing: 8) {
                    if draft.repeats == .weekly {
                        OctetSelect(selection: $draft.weekday,
                                    options: (1...7).map { ($0, CheckInRecurrence.weekdayName($0)) }, width: 130)
                            .accessibilityLabel("Weekday")
                    }
                    OctetSelect(selection: $draft.minuteOfDay, options: CheckInSettingsGroup.times, width: 110)
                        .accessibilityLabel("Time")
                }
            }
        }
        if draft.repeats != .once {
            field("Stop") {
                HStack(spacing: 8) {
                    OctetSelect(selection: $draft.stop, options: CheckInDraft.Stop.allCases.map { ($0, $0.title) }, width: 170)
                        .accessibilityLabel("Stop")
                    if draft.stop == .date {
                        OctetButton(title: CheckInInfo.dayTime(draft.stopDate).components(separatedBy: ",").first ?? "Pick…",
                                    kind: .secondary, compact: true) { picking = .stop }
                    } else if draft.stop == .count {
                        OctetNumberField(label: "Times", value: Binding(get: { Double(draft.stopCount) }, set: { draft.stopCount = Int($0) }),
                                         range: 1...1000, unit: "times", width: 130)
                    }
                }
            }
        }
    }

    private var promptFields: some View {
        VStack(alignment: .leading, spacing: 5) {
            Text("Then say").font(Theme.uiFontMedium).foregroundStyle(Theme.textSecondary)
            OctetTextEditor(placeholder: "Check the paper-trading results since last time, compare them with the benchmark, and report drift and anything unexpected.",
                            text: $draft.prompt, minHeight: 84, maxHeight: 84)
            Text("Sent to that agent's own session when it comes round, so write it as the message you'd send. Octet never runs commands itself.")
                .font(Theme.captionFont).foregroundStyle(Theme.textTertiary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private var modeFields: some View {
        VStack(alignment: .leading, spacing: 5) {
            field("Then") {
                OctetSegmented(selection: $draft.mode, items: CheckInMode.allCases.map { ($0, $0.title) })
            }
            Text(draft.mode.detail).font(Theme.captionFont).foregroundStyle(Theme.textTertiary)
                .padding(.leading, 94)
        }
    }

    private func field<Content: View>(_ title: String, @ViewBuilder _ content: () -> Content) -> some View {
        HStack(spacing: 10) {
            Text(title).font(Theme.uiFontMedium).foregroundStyle(Theme.textSecondary).frame(width: 84, alignment: .leading)
            content()
            Spacer(minLength: 0)
        }
    }

    private func save() {
        guard draft.canSave else { return }
        center.save(draft)
        close()
    }
}

// MARK: - Sidebar

/// Every check-in, docked above Waiting: when it's next due, how often, the
/// mode, and what the last one did, with a record of each in its row.
struct CheckInsDock: View {
    @ObservedObject private var center = CheckInCenter.shared
    @ObservedObject private var waits = WaitCenter.shared
    @ObservedObject private var settings = SettingsStore.shared
    @ObservedObject private var motion = MotionPreferences.shared
    @AppStorage("octet.checkInsDock.collapsed") private var collapsed = false
    @State private var expanded: Set<String> = []
    @State private var contentHeight: CGFloat = 0

    var body: some View {
        let checkIns = center.checkIns
        VStack(spacing: 0) {
            Rectangle().fill(Theme.divider).frame(height: 1)
            header(checkIns)
            if !collapsed {
                ScrollView {
                    VStack(spacing: 1) {
                        ForEach(center.stalls) { notice in StallRow(notice: notice) }
                        ForEach(checkIns) { wait in
                            CheckInRow(wait: wait, expanded: expanded.contains(wait.id)) { toggle(wait.id) }
                        }
                    }
                    .padding(.horizontal, 6)
                    .padding(.bottom, 6)
                    .onGeometryChange(for: CGFloat.self) { $0.size.height } action: { contentHeight = $0 }
                }
                .scrollIndicators(.hidden)
                .frame(height: min(max(contentHeight, 40), 260))
            }
        }
        .background(Theme.chrome)
        .onAppear {
            #if DEBUG
            if CheckInDebug.expandFirst, let first = center.checkIns.first { expanded.insert(first.id) }
            #endif
        }
    }

    private func toggle(_ id: String) {
        motion.perform(.sidebar) {
            if expanded.contains(id) { expanded.remove(id) } else { expanded.insert(id) }
        }
    }

    private func header(_ checkIns: [Wait]) -> some View {
        HStack(spacing: 6) {
            Button {
                motion.perform(.sidebar) { collapsed.toggle() }
            } label: {
                HStack(spacing: 4) {
                    OctetIcon("chevron.down", size: 12).rotationEffect(.degrees(collapsed ? -90 : 0))
                    Text("CHECK-INS").font(Theme.headerFont).kerning(0.4)
                    Text("\(checkIns.count)").font(Theme.uiFont).foregroundStyle(Theme.textTertiary)
                    if center.dueCount > 0 || !center.stalls.isEmpty {
                        Circle().fill(Theme.accent).frame(width: 6, height: 6)
                            .help(center.stalls.isEmpty ? "A check-in is due" : "A session looks stalled")
                    }
                }
                .foregroundStyle(Theme.textSecondary)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            Spacer()
            if settings.values.checkInsPaused {
                Text("Paused").font(Theme.captionFont).foregroundStyle(Theme.textTertiary)
            }
            OctetIconButton(icon: settings.values.checkInsPaused ? "play.circle" : "pause.circle",
                            help: settings.values.checkInsPaused ? "Resume all check-ins" : "Pause all check-ins",
                            active: settings.values.checkInsPaused, compact: true) {
                settings.values.checkInsPaused.toggle()
            }
            OctetIconButton(icon: "plus", help: "Check back later…", compact: true) {
                center.compose(workspaceId: WindowRegistry.shared.key?.focusedWorkspace?.workspaceId)
            }
        }
        .padding(.horizontal, 12)
        .frame(height: 30)
    }
}

/// A session that looks stalled, with what can be done about it.
private struct StallRow: View {
    let notice: CheckInCenter.StallNotice
    @ObservedObject private var center = CheckInCenter.shared
    @State private var hovered = false

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 6) {
                OctetIcon("exclamationmark.triangle.fill", size: 12).foregroundStyle(Theme.accent).frame(width: 12)
                Text(notice.label).font(Theme.interfaceFont(11.5)).foregroundStyle(Theme.textPrimary).lineLimit(1)
                Spacer(minLength: 4)
                Text(WaitSchedule.span(notice.quietFor))
                    .font(Theme.Text.mono(10.5)).foregroundStyle(Theme.textTertiary)
            }
            Text("Looks stalled: marked working, nothing for \(WaitSchedule.span(notice.quietFor))")
                .font(Theme.captionFont).foregroundStyle(Theme.textTertiary).lineLimit(1).padding(.leading, 18)
            HStack(spacing: 10) {
                Button("Resume") { center.resumeStall(notice.id) }
                    .help("Brings it forward and asks it to carry on")
                Button("Snooze") { center.snoozeStall(notice.id) }
                    .help("Ask again after another \(Int(SettingsStore.shared.values.stallHours)) hours")
                Button("Ignore") { center.ignoreStall(notice.id) }
                    .help("Not again until it does something and goes quiet")
                Spacer(minLength: 0)
            }
            .buttonStyle(.plain).font(Theme.captionFont.weight(.medium)).foregroundStyle(Theme.accent)
            .padding(.leading, 18)
        }
        .padding(.horizontal, 8).padding(.vertical, 5)
        .background(RoundedRectangle(cornerRadius: Theme.rowRadius).fill(hovered ? Theme.hover : Color.clear))
        .onHover { hovered = $0 }
    }
}

private struct CheckInRow: View {
    let wait: Wait
    let expanded: Bool
    let toggle: () -> Void
    @ObservedObject private var center = CheckInCenter.shared
    @State private var hovered = false

    private var info: CheckInInfo { wait.checkIn ?? CheckInInfo(mode: .both) }
    private var isDue: Bool { info.hasReminder && !info.isFinished }

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 6) {
                OctetIcon(info.mode.icon, size: 12)
                    .foregroundStyle(isDue ? Theme.accent : Theme.textTertiary).frame(width: 12)
                Text(wait.title).font(Theme.interfaceFont(11.5))
                    .foregroundStyle(hovered || isDue ? Theme.textPrimary : Theme.textSecondary).lineLimit(1)
                Spacer(minLength: 4)
                Text(whenLabel).font(Theme.Text.mono(10.5))
                    .foregroundStyle(isDue ? Theme.accent : Theme.textTertiary)
            }
            Text(subtitle).font(Theme.captionFont).foregroundStyle(Theme.textTertiary).lineLimit(1).padding(.leading, 18)
            if isDue {
                HStack(spacing: 10) {
                    Button(info.mode == .remind ? "Run now" : "Send now") { center.runNow(wait.id) }
                    Button("Seen") { center.dismissReminder(wait.id) }
                    Spacer(minLength: 0)
                }
                .buttonStyle(.plain).font(Theme.captionFont.weight(.medium)).foregroundStyle(Theme.accent)
                .padding(.leading, 18)
            }
            if expanded { details }
        }
        .padding(.horizontal, 8).padding(.vertical, 5)
        .background(RoundedRectangle(cornerRadius: Theme.rowRadius).fill(hovered ? Theme.hover : Color.clear))
        .contentShape(Rectangle())
        .onHover { hovered = $0 }
        .onTapGesture(perform: toggle)
        .octetContextMenu { CheckInMenu.items(for: wait) }
        .help("Then: " + wait.next + "\nSet by \(wait.createdBy), \(WaitSchedule.dateLabel(wait.createdAt))")
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(wait.title), \(subtitle), \(whenLabel)")
    }

    private var whenLabel: String {
        if info.isFinished { return "done" }
        if info.paused { return "paused" }
        if isDue { return "due" }
        return "in " + WaitSchedule.span(wait.nextCheckAt.timeIntervalSinceNow)
    }

    /// "Every day at 9:00 AM · last: resumed the session".
    private var subtitle: String {
        var parts = [info.recurrence?.summary ?? "Once"]
        if let reason = info.queuedReason, info.wakeQueued {
            parts.append(reason)
        } else if let last = info.log.last {
            parts.append("last: " + last.outcomeText.prefix(1).lowercased() + last.outcomeText.dropFirst())
        } else {
            parts.append("next " + CheckInInfo.dayTime(wait.nextCheckAt))
        }
        return parts.joined(separator: " · ")
    }

    private var details: some View {
        VStack(alignment: .leading, spacing: 5) {
            Text("Then " + info.mode.title.lowercased() + ". Next " + CheckInInfo.dayTime(wait.nextCheckAt) + ".")
                .font(Theme.captionFont).foregroundStyle(Theme.textSecondary).fixedSize(horizontal: false, vertical: true)
            if info.log.isEmpty {
                Text("Nothing has come round yet.").font(Theme.captionFont).foregroundStyle(Theme.textTertiary)
            }
            ForEach(Array(info.log.suffix(5).reversed())) { entry in
                Text(entry.line()).font(Theme.captionFont).foregroundStyle(Theme.textTertiary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            HStack(spacing: 10) {
                Button("Run") { center.runNow(wait.id) }
                if info.recurrence != nil, !info.isFinished { Button("Skip next") { center.skipNext(wait.id) } }
                Button("Edit") { center.edit(wait.id) }
                if !info.isFinished { Button(info.paused ? "Resume" : "Pause") { center.setPaused(wait.id, !info.paused) } }
                Button("Delete") { center.delete(wait.id) }
                Spacer(minLength: 0)
            }
            .lineLimit(1).fixedSize(horizontal: false, vertical: true)
            .buttonStyle(.plain).font(Theme.captionFont.weight(.medium)).foregroundStyle(Theme.accent)
        }
        .padding(.leading, 18)
        .padding(.top, 2)
    }
}

/// What can be done with a check-in, on its row's menu.
@MainActor
enum CheckInMenu {
    static func items(for wait: Wait) -> [OctetMenuItem] {
        let center = CheckInCenter.shared
        guard let info = wait.checkIn else { return [] }
        var items: [OctetMenuItem] = [
            .action("Run Now", icon: "play.circle", help: "Resume the session and send the saved prompt now; the schedule doesn't move") {
                center.runNow(wait.id)
            },
        ]
        if info.recurrence != nil, !info.isFinished {
            items.append(.action("Skip Next", icon: "arrow.right.to.line") { center.skipNext(wait.id) })
        }
        items.append(.action("Edit…", icon: "pencil") { center.edit(wait.id) })
        if !info.isFinished {
            items.append(info.paused
                ? .action("Resume", icon: "play.circle") { center.setPaused(wait.id, false) }
                : .action("Pause", icon: "pause.circle") { center.setPaused(wait.id, true) })
        }
        if info.hasReminder {
            items.append(.action("Mark Seen", icon: "checkmark.circle") { center.dismissReminder(wait.id) })
        }
        if let workspaceId = wait.origin.workspaceId {
            items.append(.divider)
            items.append(.action("Show Workspace", icon: "folder") { WindowRegistry.shared.key?.focusWorkspace(workspaceId) })
        }
        items.append(.action("Copy Prompt", icon: "doc.on.doc") {
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(wait.next, forType: .string)
        })
        items.append(.divider)
        items.append(.action("Delete", icon: "trash", destructive: true) { center.delete(wait.id) })
        return items
    }
}

// MARK: - Suggesting one

/// Over a conversation whose last reply, or whose long-running task, says
/// the result is days away: offers to check back, with the time a click away
/// and a prompt already drafted.
struct CheckInSuggestionBanner: View {
    @ObservedObject var session: AgentSession
    @ObservedObject private var settings = SettingsStore.shared
    @ObservedObject private var center = CheckInCenter.shared
    @ObservedObject private var waits = WaitCenter.shared
    @State private var dismissed: Set<String> = []

    var body: some View {
        if settings.values.suggestWaits, !session.conversation.isRunning,
           let suggestion, !dismissed.contains(suggestion.key),
           !waits.waits.contains(where: { $0.origin.conversationId == session.id && $0.state == .waiting }) {
            VStack(alignment: .leading, spacing: 6) {
                HStack(spacing: 8) {
                    OctetIcon("clock.arrow.circlepath", size: 13).foregroundStyle(Theme.accent)
                    VStack(alignment: .leading, spacing: 1) {
                        Text("Check back later?").font(Theme.uiFontMedium).foregroundStyle(Theme.textPrimary)
                        Text(suggestion.found.reason + ". Octet can bring this back, even if the session ends.")
                            .font(Theme.captionFont).foregroundStyle(Theme.textTertiary).lineLimit(1)
                    }
                    Spacer(minLength: 4)
                    Button { dismissed.insert(suggestion.key) } label: { OctetIcon("xmark", size: 12) }
                        .buttonStyle(.plain).foregroundStyle(Theme.textTertiary).help("Not now").accessibilityLabel("Not now")
                }
                HStack(spacing: 6) {
                    ForEach(CheckInSuggestion.presets(), id: \.id) { preset in
                        OctetButton(title: preset.title, kind: .secondary, compact: true) {
                            dismissed.insert(suggestion.key)
                            center.compose(workspaceId: session.workspaceId, session: session, prompt: suggestion.found.prompt,
                                           first: preset.date)
                        }
                    }
                    OctetButton(title: "Pick a Time…", kind: .ghost, compact: true) {
                        dismissed.insert(suggestion.key)
                        center.compose(workspaceId: session.workspaceId, session: session, prompt: suggestion.found.prompt,
                                       first: Date().addingTimeInterval(suggestion.found.delay), pickTime: true)
                    }
                    Spacer(minLength: 0)
                }
            }
            .padding(.horizontal, 12).padding(.vertical, 8)
            .background(RoundedRectangle(cornerRadius: Theme.Radius.lg).fill(Theme.card))
            .overlay(RoundedRectangle(cornerRadius: Theme.Radius.lg).strokeBorder(Theme.border, lineWidth: 1))
            .padding(.horizontal, 16).padding(.bottom, 6)
        }
    }

    /// What suggests it: the last reply, or a task left running for hours.
    private var suggestion: (key: String, found: CheckInSuggestion.Found)? {
        let items = session.conversation.items
        if let item = items.last(where: { item in
            if item.parent != nil { return false }
            if case .text = item.kind { return true }
            return false
        }), case .text(let text) = item.kind {
            // A wait on something Octet can watch is offered as a wait instead.
            if WaitSuggestion.detect(text) != nil { return nil }
            if let found = CheckInSuggestion.detect(text) { return (item.id, found) }
        }
        if let found = CheckInSuggestion.longRunning(CheckInSuggestion.runtimes(from: items)) {
            return ("runtime-" + session.id, found)
        }
        return nil
    }
}
