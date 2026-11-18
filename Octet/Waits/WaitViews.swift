import AppKit
import SwiftUI

/// A wait being written in the sheet: the condition as fields, the next
/// step, and where it comes back to.
struct WaitDraft: Identifiable {
    let id = UUID()
    var origin: Wait.Origin
    /// The window that asked, which shows the sheet.
    var windowId: UUID?
    var kind: WaitCondition.Kind = .pullRequest
    /// The pull request, repository, package, link, path, command or words.
    var target = ""
    var event: WaitCondition.PullRequestEvent = .merged
    var registry: WaitCondition.Registry = .npm
    var page: PageKind = .up
    var pageText = ""
    var date: Date = Calendar.current.date(byAdding: .day, value: 1, to: Date())
        .flatMap { Calendar.current.date(bySettingHour: 9, minute: 0, second: 0, of: $0) } ?? Date()
    var title = ""
    var next = ""
    var autoContinue = false
    /// Only bring the workspace back; no step to send.
    var snooze = false

    enum PageKind: String, CaseIterable, Identifiable {
        case up, changes, contains
        var id: String { rawValue }
        var title: String {
            switch self {
            case .up: "is up"
            case .changes: "changes"
            case .contains: "shows text"
            }
        }
    }

    init(origin: Wait.Origin, windowId: UUID? = nil) {
        self.origin = origin
        self.windowId = windowId
    }

    /// Nothing typed yet, so a pull request found later may fill it in.
    var isUntouched: Bool { target.isEmpty && title.isEmpty && next.isEmpty && kind == .pullRequest }

    mutating func load(_ condition: WaitCondition) {
        kind = condition.kind
        switch condition {
        case .pullRequest(let repo, let number, let event):
            target = "https://github.com/\(repo)/pull/\(number)"
            self.event = event
        case .release(let repo, let tag):
            target = repo + (tag.map { " " + $0 } ?? "")
        case .package(let registry, let name, let version):
            self.registry = registry
            target = name + (version.map { (registry == .npm ? "@" : "==") + $0 } ?? "")
        case .url(let url, let page):
            target = url
            switch page {
            case .up: self.page = .up
            case .changes: self.page = .changes
            case .contains(let text):
                self.page = .contains
                pageText = text
            }
        case .file(let path): target = path
        case .command(let command): target = command
        case .date(let date): self.date = date
        case .manual(let text): target = text
        }
    }

    /// The condition the fields describe, or nil while they don't make one.
    var condition: WaitCondition? {
        let text = target.trimmingCharacters(in: .whitespacesAndNewlines)
        switch kind {
        case .pullRequest:
            guard case .pullRequest(let repo, let number, _)? = WaitCondition.pullRequest(in: text) else { return nil }
            return .pullRequest(repo: repo, number: number, event: event)
        case .release:
            guard !text.isEmpty else { return nil }
            let parsed = text.lowercased().hasPrefix("http") ? WaitCondition.parse(text) : WaitCondition.parse("release:" + text)
            if case .release? = parsed { return parsed }
            return nil
        case .package:
            guard !text.isEmpty else { return nil }
            let parsed = WaitCondition.parse((registry == .npm ? "npm:" : "pypi:") + text)
            if case .package? = parsed { return parsed }
            return nil
        case .url:
            guard let url = URL(string: text), url.scheme?.hasPrefix("http") == true else { return nil }
            switch page {
            case .up: return .url(text, page: .up)
            case .changes: return .url(text, page: .changes)
            case .contains:
                let needle = pageText.trimmingCharacters(in: .whitespacesAndNewlines)
                return needle.isEmpty ? nil : .url(text, page: .contains(needle))
            }
        case .file:
            return text.isEmpty ? nil : WaitCondition.parse("file:" + text)
        case .command:
            return text.isEmpty ? nil : .command(text)
        case .date:
            return .date(date)
        case .manual:
            return text.isEmpty ? nil : .manual(text)
        }
    }

    var canSave: Bool {
        condition != nil && (snooze || !next.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
    }

    var placeholder: String {
        switch kind {
        case .pullRequest: "https://github.com/owner/repo/pull/12, or owner/repo#12"
        case .release: "owner/repo, or owner/repo v2.0.0 for one tag"
        case .package: registry == .npm ? "package, or package@2.0.0" : "package, or package==2.0"
        case .url: "https://status.example.com"
        case .file: "~/Downloads/certificate.p12"
        case .command: "dig +short api.example.com | grep -q ."
        case .date: ""
        case .manual: "Apple approves the build"
        }
    }

    var help: String {
        switch kind {
        case .pullRequest: "Checked with gh, so it works for private repositories you're signed in to."
        case .release: "A new release, or the tag you name. Checked with gh."
        case .package: "A new version, or the one you name."
        case .url: "Octet loads the page now and then."
        case .file: "Until the file exists."
        case .command: "Run in the folder now and then, through your login shell, until it exits 0. Up to a minute each time."
        case .date: "Comes back at this time."
        case .manual: "Octet can't check this, so it asks you every few days whether it has happened."
        }
    }
}

/// The sheet for a new wait.
struct WaitEditorSheet: View {
    @State var draft: WaitDraft
    let close: () -> Void
    @ObservedObject private var center = WaitCenter.shared

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            VStack(alignment: .leading, spacing: 3) {
                Text(draft.snooze ? "Keep in Idle until…" : "Wait for something")
                    .font(Theme.interfaceFont(15, weight: .semibold)).foregroundStyle(Theme.textPrimary)
                Text(draft.snooze
                     ? "The workspace stays in Idle and comes back when it happens."
                     : "Octet checks it with nothing running, and brings this work back with the next step when it happens.")
                    .font(Theme.uiFont).foregroundStyle(Theme.textTertiary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .padding(16)
            Rectangle().fill(Theme.divider).frame(height: 1)
            VStack(alignment: .leading, spacing: 12) {
                field("Until") {
                    OctetSelect(selection: $draft.kind,
                                options: WaitCondition.Kind.allCases.map { ($0, $0.title) }, width: 200)
                        .accessibilityLabel("Until")
                }
                conditionFields
                Text(draft.help).font(Theme.captionFont).foregroundStyle(Theme.textTertiary)
                    .fixedSize(horizontal: false, vertical: true)
                field("Name") {
                    OctetTextField(placeholder: draft.condition?.description ?? "A few words for the list", text: $draft.title)
                }
                if !draft.snooze {
                    VStack(alignment: .leading, spacing: 5) {
                        Text("Then").font(Theme.uiFontMedium).foregroundStyle(Theme.textSecondary)
                        OctetTextEditor(placeholder: "The next step", text: $draft.next, minHeight: 84, maxHeight: 84)
                        Text("Sent to the agent when it happens, so write it as the message you'd send: what to do next, and anything it will need to know.")
                            .font(Theme.captionFont).foregroundStyle(Theme.textTertiary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    Toggle("Carry on by itself when it happens", isOn: $draft.autoContinue)
                        .toggleStyle(OctetCheckboxStyle())
                }
                Text("Comes back to " + where_)
                    .font(Theme.captionFont).foregroundStyle(Theme.textTertiary)
            }
            .padding(16)
            Rectangle().fill(Theme.divider).frame(height: 1)
            HStack {
                Spacer()
                OctetButton(title: "Cancel", kind: .secondary, compact: true, action: close).keyboardShortcut(.cancelAction)
                OctetButton(title: draft.snooze ? "Move to Idle" : "Set Wait", kind: .primary, compact: true, action: save)
                    .keyboardShortcut(.defaultAction)
                    .disabled(!draft.canSave)
            }
            .padding(12)
        }
        .frame(width: 460)
        .background(Theme.chrome)
    }

    private var where_: String {
        var place = draft.origin.workspaceLabel ?? HandoffBrief.abbreviate(draft.origin.cwd)
        if let branch = draft.origin.branch { place += " on \(branch)" }
        if let agent = draft.origin.agent { place += " · " + (AgentBrand.forAgent(agent)?.displayName ?? agent) }
        return place
    }

    @ViewBuilder private var conditionFields: some View {
        switch draft.kind {
        case .date:
            field("When") {
                DatePicker("When", selection: $draft.date, in: Date()..., displayedComponents: [.date, .hourAndMinute])
                    .labelsHidden()
            }
        case .pullRequest:
            field("Pull request") { OctetTextField(placeholder: draft.placeholder, text: $draft.target) }
            field("Until it") {
                OctetSelect(selection: $draft.event,
                            options: WaitCondition.PullRequestEvent.allCases.map { ($0, $0.title) }, width: 200)
                    .accessibilityLabel("Until it")
            }
        case .package:
            field("Registry") {
                OctetSegmented(selection: $draft.registry,
                               items: WaitCondition.Registry.allCases.map { ($0, $0.title) })
            }
            field("Package") { OctetTextField(placeholder: draft.placeholder, text: $draft.target) }
        case .url:
            field("Page") { OctetTextField(placeholder: draft.placeholder, text: $draft.target) }
            field("Until it") {
                OctetSegmented(selection: $draft.page,
                               items: WaitDraft.PageKind.allCases.map { ($0, $0.title) })
            }
            if draft.page == .contains {
                field("Text") { OctetTextField(placeholder: "Version 2 is live", text: $draft.pageText) }
            }
        case .release:
            field("Repository") { OctetTextField(placeholder: draft.placeholder, text: $draft.target) }
        case .file:
            field("File") { OctetTextField(placeholder: draft.placeholder, text: $draft.target) }
        case .command:
            field("Command") { OctetTextField(placeholder: draft.placeholder, text: $draft.target) }
        case .manual:
            field("What") { OctetTextField(placeholder: draft.placeholder, text: $draft.target) }
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
        guard let condition = draft.condition else { return }
        if draft.snooze, let workspaceId = draft.origin.workspaceId {
            center.snooze(workspaceId: workspaceId, until: condition, title: draft.title)
        } else {
            let session = draft.origin.conversationId.flatMap { id in AgentCenter.shared.sessions.first { $0.id == id } }
            let title = draft.title.trimmingCharacters(in: .whitespacesAndNewlines)
            let wait = Wait(title: title, condition: condition, next: draft.next, origin: draft.origin,
                            brief: WaitCenter.brief(for: session, branch: draft.origin.branch,
                                                    waitingFor: title.isEmpty ? condition.description : title)
                                ?? WaitCenter.brief(origin: draft.origin, waitingFor: title.isEmpty ? condition.description : title),
                            autoContinue: draft.autoContinue)
            center.add(wait)
            ToastCenter.shared.info("Waiting for \(wait.title)", detail: "It's in the sidebar under Waiting.")
        }
        close()
    }
}

extension WaitCondition.Kind {
    var icon: String {
        switch self {
        case .pullRequest: "arrow.triangle.branch"
        case .release: "square.and.arrow.down"
        case .package: "square.stack.3d.up"
        case .url: "safari"
        case .file: "doc"
        case .command: "terminal"
        case .date: "clock"
        case .manual: "checkmark.circle"
        }
    }
}

// MARK: - Sidebar

/// Ready waits, at the top of the sidebar: what happened and the next step,
/// with Continue.
struct ReadyWaits: View {
    @ObservedObject private var center = WaitCenter.shared
    @EnvironmentObject private var window: WindowContext

    var body: some View {
        if !center.ready.isEmpty {
            VStack(alignment: .leading, spacing: 4) {
                Text("READY").font(Theme.headerFont).kerning(0.4).foregroundStyle(Theme.accent)
                    .padding(.horizontal, 12)
                ForEach(center.ready) { wait in
                    ReadyCard(wait: wait)
                }
            }
        }
    }
}

private struct ReadyCard: View {
    let wait: Wait
    @EnvironmentObject private var window: WindowContext
    @State private var hovered = false

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 6) {
                OctetIcon(wait.condition.kind.icon, size: 12).foregroundStyle(Theme.accent)
                Text(wait.title).font(Theme.uiFontMedium).foregroundStyle(Theme.textPrimary).lineLimit(2)
                Spacer(minLength: 0)
            }
            if let result = wait.lastResult {
                Text(result + " · " + WorkspaceActivity.ageLabel(since: wait.readyAt)).font(Theme.captionFont).foregroundStyle(Theme.textTertiary)
            }
            Text("Next: " + wait.next).font(Theme.captionFont).foregroundStyle(Theme.textSecondary).lineLimit(3)
            HStack(spacing: 6) {
                OctetButton(title: "Continue", kind: .primary, compact: true) { WaitCenter.shared.continueWait(wait.id, in: window) }
                Spacer(minLength: 0)
                Text(wait.origin.workspaceLabel ?? URL(fileURLWithPath: wait.origin.cwd).lastPathComponent)
                    .font(Theme.captionFont).foregroundStyle(Theme.textTertiary).lineLimit(1)
            }
        }
        .padding(10)
        .background(RoundedRectangle(cornerRadius: Theme.Radius.md).fill(hovered ? Theme.cardSelected : Theme.card))
        .overlay(RoundedRectangle(cornerRadius: Theme.Radius.md).strokeBorder(Theme.accent.opacity(0.5), lineWidth: 1))
        .padding(.horizontal, 8)
        .onHover { hovered = $0 }
        .contextMenu { WaitMenu(wait: wait) }
        .help(wait.next)
    }
}

/// Every wait still waiting, docked above Idle: what, and where it stands.
/// Dressed as the Idle and Snoozed shelves below it (name and count, a
/// hairline, a chevron), so the three read as one dock.
struct WaitsDock: View {
    @ObservedObject private var center = WaitCenter.shared
    @ObservedObject private var motion = MotionPreferences.shared
    @AppStorage("octet.waitsDock.collapsed") private var collapsed = false
    /// The rows' height as laid out, so the dock opens to exactly them.
    @State private var contentHeight: CGFloat = 0

    private static let maxHeight: CGFloat = 220
    /// The header and the gap above it.
    private static let headerBlock: CGFloat = IdleDock.headerHeight + 4

    var body: some View {
        let waiting = center.waiting
        let asking = waiting.contains { $0.needsAnswer() }
        VStack(spacing: 0) {
            Rectangle().fill(Theme.divider).frame(height: 1)
            ShelfHeader(title: "Waiting", count: waiting.count, tone: .muted,
                        help: "Things Octet is watching for. Each brings its work back when it happens.",
                        collapsed: $collapsed) { hovered in
                if asking {
                    AttentionDot().help("One asks you something").transition(.scale(scale: 0.4).combined(with: .opacity))
                }
                Button { WaitCenter.shared.compose(workspaceId: WindowRegistry.shared.key?.focusedWorkspace?.workspaceId) } label: {
                    OctetIcon("plus", size: 12).frame(width: 18, height: 18).contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .foregroundStyle(Theme.textTertiary)
                .hoverReveal(hovered)
                .help("Wait for something…")
                .accessibilityLabel("Wait for something")
            }
            .padding(.horizontal, 6)
            .padding(.top, 4)
            // The list never changes as the dock folds: it stays as it is and
            // the container's height runs over it, so it only looks like the
            // dock moving up or down.
            ScrollView {
                VStack(spacing: 2) {
                    ForEach(waiting) { wait in WaitRow(wait: wait) }
                }
                .padding(.horizontal, 6)
                .padding(.bottom, 6)
                .onGeometryChange(for: CGFloat.self) { $0.size.height } action: { contentHeight = $0 }
            }
            .scrollIndicators(.hidden)
            // Always its full height; the frame around the whole dock is what
            // runs, so nothing inside is laid out again while it moves.
            .frame(height: min(contentHeight, Self.maxHeight))
            .allowsHitTesting(!collapsed)
            .accessibilityHidden(collapsed)
        }
        // The one thing that animates: the dock's own height, from just its
        // header to header and rows. Everything inside stays put, top-aligned,
        // and is revealed or covered as the height moves.
        .frame(height: 1 + Self.headerBlock + (collapsed ? 0 : min(contentHeight, Self.maxHeight)), alignment: .top)
        .animation(motion.animation(.sidebar, IdleDock.spring), value: collapsed)
        .animation(motion.animation(.sidebar, IdleDock.spring), value: contentHeight)
        .background(Theme.chrome)
        .clipped()
    }
}

/// The accent dot for "this asks you something", with a slow ring that
/// swells out of it; still when motion is off.
private struct AttentionDot: View {
    @ObservedObject private var motion = MotionPreferences.shared
    @State private var swell = false

    var body: some View {
        Circle().fill(Theme.accent).frame(width: 6, height: 6)
            .background(
                Circle().stroke(Theme.accent, lineWidth: 1)
                    .scaleEffect(swell ? 2.4 : 1)
                    .opacity(swell ? 0 : 0.6)
            )
            .onAppear {
                guard motion.animates(.sidebar) else { return }
                withAnimation(.easeOut(duration: 1.6).repeatForever(autoreverses: false)) { swell = true }
            }
    }
}

/// A small answer button on a wait: the likely answer filled, the other quiet.
private struct WaitPill: View {
    let title: String
    var prominent = false
    let action: () -> Void
    @ObservedObject private var motion = MotionPreferences.shared
    @State private var hovered = false

    var body: some View {
        Button(action: action) {
            Text(title)
                .font(Theme.captionFont.weight(.medium))
                .foregroundStyle(prominent ? Theme.accent : hovered ? Theme.textPrimary : Theme.textSecondary)
                .padding(.horizontal, 8)
                .frame(height: 20)
                .background(Capsule().fill(prominent ? Theme.accent.opacity(hovered ? 0.24 : 0.14)
                                                     : hovered ? Theme.cardSelected : Theme.hover.opacity(0.6))
                    .animation(motion.animation(.sidebar, .easeOut(duration: 0.12)), value: hovered))
                .contentShape(Capsule())
        }
        .buttonStyle(OctetPressStyle())
        .onHover { hovered = $0 }
    }
}

private struct WaitRow: View {
    let wait: Wait
    @ObservedObject private var center = WaitCenter.shared
    @ObservedObject private var motion = MotionPreferences.shared
    @State private var hovered = false

    var body: some View {
        let asking = wait.needsAnswer()
        let checking = center.isChecking(wait.id)
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 8) {
                OctetIcon(wait.condition.kind.icon, size: 12)
                    .foregroundStyle(asking ? Theme.accent : Theme.textTertiary)
                    .frame(width: 16, height: 16)
                Text(wait.title).font(Theme.Text.transcript)
                    .foregroundStyle(hovered || asking ? Theme.textPrimary : Theme.textSecondary).lineLimit(1)
                Spacer(minLength: 4)
                Text(WorkspaceActivity.ageLabel(since: wait.createdAt))
                    .font(Theme.interfaceFont(11.5).monospacedDigit()).foregroundStyle(Theme.textTertiary)
            }
            Text(checking ? "Checking…" : wait.statusLine())
                .font(Theme.captionFont).foregroundStyle(checking ? Theme.accent : Theme.textTertiary).lineLimit(1)
                .padding(.leading, 24)
                .contentTransition(.opacity)
                .animation(motion.animation(.sidebar, .easeOut(duration: 0.2)), value: checking)
            if asking {
                HStack(spacing: 6) {
                    Text(wait.isManual ? "Happened?" : "Still needed?")
                        .font(Theme.captionFont).foregroundStyle(Theme.textSecondary).lineLimit(1).fixedSize()
                    Spacer(minLength: 0)
                    if wait.isManual {
                        WaitPill(title: "Not yet") { center.confirm(wait.id) }
                        WaitPill(title: "Yes", prominent: true) { center.markReady(wait.id) }
                    } else {
                        WaitPill(title: "Remove") { center.remove(wait.id) }
                        WaitPill(title: "Keep", prominent: true) { center.confirm(wait.id) }
                    }
                }
                .padding(.leading, 24)
                .padding(.top, 2)
                .transition(.opacity.combined(with: .offset(y: -3)))
            }
        }
        .padding(.horizontal, 10).padding(.vertical, 7)
        .background(RoundedRectangle(cornerRadius: Theme.controlRadius)
            .fill(asking ? Theme.accent.opacity(hovered ? 0.1 : 0.06) : hovered ? Theme.hover : Color.clear)
            .animation(motion.animation(.sidebar, .easeOut(duration: 0.12)), value: hovered))
        .overlay(RoundedRectangle(cornerRadius: Theme.controlRadius)
            .strokeBorder(asking ? Theme.accent.opacity(0.2) : .clear, lineWidth: 1))
        .contentShape(Rectangle())
        .onHover { hovered = $0 }
        .contextMenu { WaitMenu(wait: wait) }
        .help("Then: " + wait.next + "\nSet by \(wait.createdBy), \(WaitSchedule.dateLabel(wait.createdAt))")
    }
}

/// What can be done with a wait, on its row's menu.
struct WaitMenu: View {
    let wait: Wait

    var body: some View {
        let center = WaitCenter.shared
        if wait.state == .ready {
            Button("Continue") { center.continueWait(wait.id) }
        } else {
            if !wait.isManual { Button("Check Now") { center.checkNow(wait.id) } }
            Button("It's Happened") { center.markReady(wait.id) }
            Button("Continue Now") { center.continueWait(wait.id) }
            Toggle("Carry On by Itself", isOn: Binding(get: { wait.autoContinue }, set: { value in
                var changed = wait
                changed.autoContinue = value
                center.update(changed)
            }))
        }
        if let link = wait.condition.link {
            Button("Open \(link.host ?? "Link")") { NSWorkspace.shared.open(link) }
        }
        Button("Copy Next Step") {
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(wait.next, forType: .string)
        }
        Divider()
        Button("Remove") { center.remove(wait.id) }
    }
}

// MARK: - Suggesting one

/// Over a finished conversation whose last reply leaves work waiting on
/// something outside it: offers to write it down as a wait.
struct WaitSuggestionBanner: View {
    @ObservedObject var session: AgentSession
    @ObservedObject private var settings = SettingsStore.shared
    @ObservedObject private var center = WaitCenter.shared
    /// Replies already offered or turned down, by item id.
    @State private var dismissed: Set<String> = []

    var body: some View {
        if settings.values.suggestWaits, !session.conversation.isRunning,
           let suggestion, !dismissed.contains(suggestion.itemId),
           !center.waits.contains(where: { $0.origin.conversationId == session.id && $0.state == .waiting }) {
            HStack(spacing: 8) {
                OctetIcon("clock", size: 13).foregroundStyle(Theme.accent)
                VStack(alignment: .leading, spacing: 1) {
                    Text("Waiting on \(suggestion.found.waitingFor)?").font(Theme.uiFontMedium).foregroundStyle(Theme.textPrimary).lineLimit(1)
                    Text("Octet can watch for it and bring this back with the next step.")
                        .font(Theme.captionFont).foregroundStyle(Theme.textTertiary).lineLimit(1)
                }
                Spacer(minLength: 4)
                OctetButton(title: "Set a Wait…", kind: .primary, compact: true) {
                    dismissed.insert(suggestion.itemId)
                    center.compose(workspaceId: session.workspaceId, session: session, prefill: suggestion.found)
                }
                Button { dismissed.insert(suggestion.itemId) } label: { OctetIcon("xmark", size: 12) }
                    .buttonStyle(.plain).foregroundStyle(Theme.textTertiary).help("Not now").accessibilityLabel("Not now")
            }
            .padding(.horizontal, 12).padding(.vertical, 8)
            .background(RoundedRectangle(cornerRadius: Theme.Radius.lg).fill(Theme.card))
            .overlay(RoundedRectangle(cornerRadius: Theme.Radius.lg).strokeBorder(Theme.border, lineWidth: 1))
            .padding(.horizontal, 16).padding(.bottom, 6)
        }
    }

    /// The last reply, if it leaves something waiting.
    private var suggestion: (itemId: String, found: WaitSuggestion.Found)? {
        guard let item = session.conversation.items.last(where: { item in
            if item.parent != nil { return false }
            if case .text = item.kind { return true }
            return false
        }), case .text(let text) = item.kind, let found = WaitSuggestion.detect(text) else { return nil }
        return (itemId: item.id, found: found)
    }
}
