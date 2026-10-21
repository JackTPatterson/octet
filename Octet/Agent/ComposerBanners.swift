import SwiftUI

/// Over the composer when the agent's last turn ended on a plan, as T3
/// Code's plan follow-up: carry it out, keep refining it, or dismiss it.
struct PlanFollowUpBanner: View {
    let plan: ComposerPlanFollowUp.Plan
    /// Refine sends the draft; without one it puts the cursor in the box.
    let hasDraft: Bool
    let implement: () -> Void
    let refine: () -> Void
    let dismiss: () -> Void

    var body: some View {
        HStack(spacing: 8) {
            OctetIcon("tool.todo", size: 13).foregroundStyle(Theme.accent)
            Text("Plan ready")
                .font(Theme.uiFontMedium)
                .foregroundStyle(Theme.textSecondary)
                .fixedSize()
            if let title = plan.title {
                Text(title)
                    .font(Theme.uiFont)
                    .foregroundStyle(Theme.textPrimary)
                    .lineLimit(1)
                    .truncationMode(.tail)
            }
            Spacer(minLength: 8)
            OctetButton(title: "Refine", kind: .secondary, compact: true, action: refine)
                .help(hasDraft ? "Send what's in the message box as changes to the plan, staying in plan mode"
                               : "Write what should change in the plan, staying in plan mode")
            OctetButton(title: "Implement this plan", icon: "play.circle", kind: .primary, compact: true, action: implement)
                .help("Leave plan mode and ask the agent to carry the plan out")
            OctetIconButton(icon: "xmark", help: "Dismiss", compact: true, action: dismiss)
                .accessibilityLabel("Dismiss plan banner")
        }
        .padding(.leading, 10)
        .padding(.trailing, 4)
        .padding(.vertical, 4)
        .background(RoundedRectangle(cornerRadius: Theme.Radius.card, style: .continuous).fill(Theme.accent.opacity(0.08)))
        .overlay(RoundedRectangle(cornerRadius: Theme.Radius.card, style: .continuous).strokeBorder(Theme.accent.opacity(0.25), lineWidth: 1))
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Plan ready" + (plan.title.map { ": \($0)" } ?? ""))
        .onAppear { AccessibilityNotification.Announcement("The plan is ready").post() }
    }
}

/// Text with some characters lit, e.g. the letters a search matched.
struct MatchHighlightedText: View {
    let text: String
    /// Character offsets into `text`.
    let indices: [Int]
    let base: Color
    let lit: Color

    var body: some View {
        Text(attributed)
    }

    private var attributed: AttributedString {
        var result = AttributedString()
        let litOffsets = Set(indices)
        // Runs of lit and unlit characters, not one attribute per letter.
        var run = ""
        var runLit = false
        func flush() {
            guard !run.isEmpty else { return }
            var piece = AttributedString(run)
            piece.foregroundColor = runLit ? lit : base
            if runLit { piece.inlinePresentationIntent = .stronglyEmphasized }
            result += piece
            run = ""
        }
        for (offset, character) in text.enumerated() {
            let on = litOffsets.contains(offset)
            if on != runLit {
                flush()
                runLit = on
            }
            run.append(character)
        }
        flush()
        return result
    }
}

/// Under the message, when it's long enough to matter: its size in tokens,
/// and when it's very long, that sending will ask first.
struct PromptLengthNotice: View {
    let verdict: ComposerPromptLength.Verdict

    var body: some View {
        if let notice = ComposerPromptLength.notice(verdict) {
            let severe = { if case .tooLong = verdict { return true } else { return false } }()
            HStack(spacing: 6) {
                OctetIcon(severe ? "exclamationmark.triangle.fill" : "text.bubble", size: 11)
                Text(notice + (severe ? " Sending will ask first." : ""))
                    .lineLimit(2)
                Spacer(minLength: 0)
            }
            .font(Theme.captionFont)
            .foregroundStyle(severe ? Theme.danger : Theme.textTertiary)
            .padding(.horizontal, 5)
            .accessibilityElement(children: .combine)
            .accessibilityAddTraits(severe ? .isStaticText : [])
        }
    }
}
