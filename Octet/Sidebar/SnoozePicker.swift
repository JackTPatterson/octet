import AppKit
import SwiftUI

/// Snooze › Pick a Time…, after T3 Code's CustomSnoozeDialog: quick
/// presets, or a day on a small calendar and a time, all Octet's own
/// controls rather than the system date picker.
@MainActor
final class SnoozePickerCenter: ObservableObject {
    struct Request: Identifiable {
        let id = UUID()
        let workspaceId: String
        let label: String
        weak var store: SessionStore?
        /// The window in front when asked; it draws the dialog.
        weak var window: NSWindow?
    }

    static let shared = SnoozePickerCenter()
    @Published private(set) var request: Request?

    func ask(store: SessionStore, workspaceId: String) {
        let label = store.snapshot.workspaces.first { $0.workspaceId == workspaceId }?.label ?? "Workspace"
        request = Request(workspaceId: workspaceId, label: label, store: store, window: NSApp.keyWindow)
        DebugSnapshot.overlay("snooze-picker", true)
    }

    func finish(_ date: Date?) {
        guard let request else { return }
        self.request = nil
        DebugSnapshot.overlay("snooze-picker", false)
        if let date { request.store?.snooze(request.workspaceId, until: date) }
    }
}

extension SessionStore {
    /// Snoozes until a picked time, as `snooze(_:_:)` does for a choice.
    func snooze(_ workspaceId: String, until wake: Date) {
        WaitCenter.shared.cancelSnooze(of: workspaceId)
        markIdle(workspaceId, wakeAt: wake)
        guard let label = snapshot.workspaces.first(where: { $0.workspaceId == workspaceId })?.label else { return }
        ToastCenter.shared.info("\(label) is snoozed", detail: "Back " + IdleShelves.wakeDescription(wake), after: 6,
                                action: .init(title: "Undo") { [weak self] in self?.keepInView(workspaceId) })
    }
}

extension WorkspaceMenu {
    /// The menu row that opens the picker.
    static func pickSnoozeTime(store: SessionStore, workspaceId: String) -> OctetMenuItem {
        .action("Pick a Time…") { SnoozePickerCenter.shared.ask(store: store, workspaceId: workspaceId) }
    }
}

struct SnoozePickerHost: View {
    @ObservedObject var center = SnoozePickerCenter.shared
    @ObservedObject private var motion = MotionPreferences.shared
    @StateObject private var host = HostWindow()

    var body: some View {
        ZStack {
            if let request = center.request, host.owns(request.window) {
                Theme.scrim
                    .ignoresSafeArea()
                    .onTapGesture { center.finish(nil) }
                SnoozePickerDialog(label: request.label) { center.finish($0) }
                    .id(request.id)
                    .transition(motion.animates(.palette)
                        ? .opacity.combined(with: .scale(scale: 0.96))
                        : .identity)
            }
        }
        .animation(motion.animation(.palette, .smooth(duration: 0.16)), value: center.request?.id)
        .background(HostWindowReader(host: host))
    }
}

struct SnoozePickerDialog: View {
    let label: String
    let finish: (Date?) -> Void
    /// The same dialog for other things that happen at a picked time (a
    /// check-in): its own words, button and extra presets.
    var heading: String?
    var blurb: String?
    var confirmTitle = "Snooze"
    var resultPrefix = "Back "
    var extraPresets: (Date, Calendar) -> [CustomSnooze.Preset] = { _, _ in [] }
    @State private var day: Date
    @State private var month: Date
    @State private var hour12: Int
    @State private var minute: Int
    @State private var pm: Bool
    @State private var hoveredPreset: String?
    @State private var now = Date()
    private let calendar = Calendar.current

    init(label: String, heading: String? = nil, blurb: String? = nil, confirmTitle: String = "Snooze",
         resultPrefix: String = "Back ", extraPresets: @escaping (Date, Calendar) -> [CustomSnooze.Preset] = { _, _ in [] },
         finish: @escaping (Date?) -> Void) {
        self.label = label
        self.finish = finish
        self.heading = heading
        self.blurb = blurb
        self.confirmTitle = confirmTitle
        self.resultPrefix = resultPrefix
        self.extraPresets = extraPresets
        let pick = CustomSnooze.initialPick()
        let clock = CustomSnooze.hour12(pick.hour)
        _day = State(initialValue: pick.day)
        _month = State(initialValue: pick.day)
        _hour12 = State(initialValue: clock.hour)
        _minute = State(initialValue: pick.minute)
        _pm = State(initialValue: clock.pm)
    }

    private var picked: Date? {
        CustomSnooze.date(day: day, hour: CustomSnooze.hour24(hour12, pm: pm), minute: minute, calendar: calendar)
    }

    private var problem: String? { CustomSnooze.problem(with: picked, now: now) }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            VStack(alignment: .leading, spacing: 4) {
                Text(heading ?? "Snooze “\(label)”")
                    .font(Theme.interfaceFont(13, weight: .semibold))
                    .foregroundStyle(Theme.textPrimary)
                    .lineLimit(1)
                Text(blurb ?? "It leaves the sidebar and comes back at the time you pick.")
                    .font(Theme.uiFont)
                    .foregroundStyle(Theme.textSecondary)
            }
            presets
            Rectangle().fill(Theme.divider).frame(height: 1)
            calendarPage
            timeRow
            HStack(spacing: 6) {
                OctetIcon("clock", size: 12)
                if let problem {
                    Text(problem).foregroundStyle(Theme.danger)
                } else if let picked {
                    Text(resultPrefix + IdleShelves.wakeDescription(picked, now: now))
                }
            }
            .font(Theme.captionFont)
            .foregroundStyle(Theme.textTertiary)
            HStack(spacing: 8) {
                Spacer()
                OctetButton(title: "Cancel") { finish(nil) }
                    .keyboardShortcut(.cancelAction)
                OctetButton(title: confirmTitle, kind: .primary) {
                    if problem == nil, let picked { finish(picked) }
                }
                .keyboardShortcut(.defaultAction)
                .disabled(problem != nil)
            }
        }
        .padding(16)
        .frame(width: 340)
        .octetGlass(cornerRadius: 18, fill: Theme.card)
        .onReceive(Timer.publish(every: 30, on: .main, in: .common).autoconnect()) { now = $0 }
    }

    // MARK: Presets

    private var presets: some View {
        VStack(spacing: 0) {
            ForEach((CustomSnooze.presets(now: now, calendar: calendar) + extraPresets(now, calendar)).sorted { $0.date < $1.date }) { preset in
                Button { finish(preset.date) } label: {
                    HStack {
                        Text(preset.title)
                            .font(Theme.uiFont)
                            .foregroundStyle(Theme.textPrimary)
                        Spacer()
                        Text(IdleShelves.wakeDescription(preset.date, now: now))
                            .font(Theme.captionFont)
                            .foregroundStyle(Theme.textTertiary)
                    }
                    .padding(.horizontal, 8)
                    .frame(height: 26)
                    .background(RoundedRectangle(cornerRadius: Theme.controlRadius)
                        .fill(hoveredPreset == preset.id ? Theme.hover : .clear))
                    .contentShape(Rectangle())
                }
                .buttonStyle(OctetPressStyle())
                .onHover { hoveredPreset = $0 ? preset.id : (hoveredPreset == preset.id ? nil : hoveredPreset) }
            }
        }
        .padding(.horizontal, -8)
    }

    // MARK: Calendar

    private var calendarPage: some View {
        VStack(spacing: 6) {
            HStack {
                Text(month.formatted(.dateTime.month(.wide).year()))
                    .font(Theme.uiFontMedium)
                    .foregroundStyle(Theme.textPrimary)
                Spacer()
                OctetIconButton(icon: "chevron.left", help: "Previous Month") { shiftMonth(-1) }
                    .disabled(calendar.isDate(month, equalTo: now, toGranularity: .month))
                OctetIconButton(icon: "chevron.right", help: "Next Month") { shiftMonth(1) }
            }
            let columns = Array(repeating: GridItem(.flexible(), spacing: 2), count: 7)
            LazyVGrid(columns: columns, spacing: 2) {
                ForEach(Array(CustomSnooze.weekdaySymbols(calendar: calendar).enumerated()), id: \.offset) { _, symbol in
                    Text(symbol)
                        .font(Theme.captionFont)
                        .foregroundStyle(Theme.textMuted)
                        .frame(height: 18)
                }
                ForEach(Array(CustomSnooze.monthGrid(containing: month, calendar: calendar).enumerated()), id: \.offset) { _, cell in
                    if let cell {
                        dayCell(cell)
                    } else {
                        Color.clear.frame(height: 26)
                    }
                }
            }
        }
    }

    private func dayCell(_ date: Date) -> some View {
        let chosen = calendar.isDate(date, inSameDayAs: day)
        let past = date < calendar.startOfDay(for: now)
        let today = calendar.isDateInToday(date)
        return Button { day = date } label: {
            Text("\(calendar.component(.day, from: date))")
                .font(Theme.interfaceFont(11.5, weight: chosen || today ? .semibold : .regular).monospacedDigit())
                .foregroundStyle(chosen ? Theme.onAccent : Theme.textPrimary)
                .opacity(past && !chosen ? 0.3 : 1)
                .frame(maxWidth: .infinity)
                .frame(height: 26)
                .background(RoundedRectangle(cornerRadius: Theme.controlRadius)
                    .fill(chosen ? Theme.accent : .clear))
                .overlay(RoundedRectangle(cornerRadius: Theme.controlRadius)
                    .strokeBorder(today && !chosen ? Theme.accent.opacity(0.6) : .clear, lineWidth: 1))
                .contentShape(Rectangle())
        }
        .buttonStyle(OctetPressStyle())
        .disabled(past)
        .accessibilityLabel(date.formatted(date: .complete, time: .omitted))
        .accessibilityAddTraits(chosen ? [.isButton, .isSelected] : .isButton)
    }

    private func shiftMonth(_ delta: Int) {
        guard let next = calendar.date(byAdding: .month, value: delta, to: month) else { return }
        month = next
    }

    // MARK: Time

    private var timeRow: some View {
        HStack(spacing: 6) {
            Text("Time")
                .font(Theme.uiFontMedium)
                .foregroundStyle(Theme.textTertiary)
            Spacer()
            OctetSelect(selection: $hour12, options: (1...12).map { ($0, "\($0)") }, width: 64)
            Text(":").foregroundStyle(Theme.textTertiary)
            OctetSelect(selection: $minute, options: minuteOptions, width: 64)
            OctetSegmented(selection: $pm, items: [(false, "AM"), (true, "PM")])
        }
    }

    /// Every five minutes, plus the one picked if it's between them.
    private var minuteOptions: [(value: Int, title: String)] {
        Set(Array(stride(from: 0, to: 60, by: 5)) + [minute]).sorted().map { ($0, String(format: "%02d", $0)) }
    }
}
