import SwiftUI

/// The small bottom-corner surface used when an agent pauses for the person.
/// It uses the conversation's real pending request, so answering here clears
/// the full card and resumes the same process.
struct AgentQuickAnswerHost: View {
    @ObservedObject var center: AgentCenter
    @ObservedObject var twin: TwinSession
    let workspaceId: String?
    @ObservedObject private var settings = SettingsStore.shared
    @ObservedObject private var motion = MotionPreferences.shared

    private var localSession: AgentSession? {
        center.sessions(in: workspaceId).first(where: Self.needsAnswer)
    }

    private var backgroundSession: AgentSession? {
        center.sessions.first { $0.workspaceId != workspaceId && Self.needsAnswer($0) }
    }

    private var requestId: String? {
        guard settings.values.agentQuickAnswers else { return nil }
        if let session = localSession ?? backgroundSession {
            return session.pendingPermission?.id ?? session.pendingQuestion?.id
        }
        return twin.approval.map { approval in
            "twin|\(approval.question)|\(approval.options.map(\.id).joined(separator: ","))"
        }
    }

    var body: some View {
        Group {
            if settings.values.agentQuickAnswers, let session = localSession {
                AgentSessionQuickAnswer(session: session, isBackground: false)
            } else if settings.values.agentQuickAnswers, let approval = twin.approval {
                TwinQuickAnswer(twin: twin, approval: approval)
            } else if settings.values.agentQuickAnswers, let session = backgroundSession {
                AgentSessionQuickAnswer(session: session, isBackground: true)
            }
        }
        .id(requestId)
        .transition(motion.animates(.approvals)
            ? .asymmetric(insertion: .move(edge: .trailing).combined(with: .opacity), removal: .opacity)
            : .identity)
        .animation(motion.animation(.approvals, .smooth(duration: 0.24)), value: requestId)
        .onAppear { DebugSnapshot.overlay("quick-answer", requestId != nil) }
        .onChange(of: requestId) { _, id in DebugSnapshot.overlay("quick-answer", id != nil) }
        .onDisappear { DebugSnapshot.overlay("quick-answer", false) }
    }

    private static func needsAnswer(_ session: AgentSession) -> Bool {
        session.pendingPermission != nil || session.pendingQuestion != nil
    }
}

private struct AgentSessionQuickAnswer: View {
    @ObservedObject var session: AgentSession
    let isBackground: Bool

    var body: some View {
        QuickAnswerShell(
            agent: session.engine.agent,
            title: session.engine.displayName,
            context: isBackground ? session.title : nil
        ) {
            if let permission = session.pendingPermission {
                QuickPermission(session: session, request: permission)
            } else if let question = session.pendingQuestion {
                QuickQuestion(session: session, question: question)
            }
        }
    }
}

private struct TwinQuickAnswer: View {
    @ObservedObject var twin: TwinSession
    let approval: TwinApproval

    var body: some View {
        QuickAnswerShell(
            agent: twin.focusedAgent?.agent ?? "agent",
            title: AgentBrand.forAgent(twin.focusedAgent?.agent)?.displayName ?? "Agent"
        ) {
            VStack(alignment: .leading, spacing: 10) {
                QuickQuestionText(approval.question, detail: approval.detail)
                QuickChoiceFlow {
                    ForEach(approval.options) { option in
                        OctetButton(
                            title: option.label,
                            kind: option.isAffirmative ? .primary : .secondary,
                            compact: true
                        ) { twin.answer(option) }
                    }
                }
            }
        }
    }
}

private struct QuickPermission: View {
    @ObservedObject var session: AgentSession
    let request: AgentPermissionRequest

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            QuickQuestionText("Allow \(request.toolName)?", detail: request.summary)
            QuickChoiceFlow {
                OctetButton(title: "Deny", kind: .secondary, compact: true) {
                    session.answerPermission(allow: false)
                }
                OctetButton(title: "This Session", kind: .secondary, compact: true) {
                    session.answerPermission(allow: true, forSession: true)
                }
                OctetButton(title: "Allow", kind: .primary, compact: true) {
                    session.answerPermission(allow: true)
                }
            }
        }
        .onAppear {
            AccessibilityNotification.Announcement(
                "\(session.engine.displayName) asks to use \(request.toolName)"
            ).post()
        }
    }
}

private struct QuickQuestion: View {
    @ObservedObject var session: AgentSession
    let question: OpenCodeQuestion
    @State private var picked: [Int: Set<String>] = [:]
    @State private var typed: [Int: String] = [:]

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            ScrollView {
                VStack(alignment: .leading, spacing: 12) {
                    ForEach(Array(question.items.enumerated()), id: \.offset) { index, item in
                        VStack(alignment: .leading, spacing: 7) {
                            if !item.header.isEmpty {
                                Text(item.header.uppercased())
                                    .font(Theme.headerFont)
                                    .kerning(0.4)
                                    .foregroundStyle(Theme.textTertiary)
                            }
                            Text(item.question)
                                .font(Theme.uiFontMedium)
                                .foregroundStyle(Theme.textPrimary)
                                .fixedSize(horizontal: false, vertical: true)
                            ForEach(item.options, id: \.label) { option in
                                optionRow(option, item: item, index: index)
                            }
                            if item.custom {
                                OctetTextField(
                                    placeholder: item.options.isEmpty ? "Your answer" : "Or type your own answer",
                                    text: Binding(
                                        get: { typed[index] ?? item.initial },
                                        set: { typed[index] = $0 }
                                    ),
                                    secure: item.secret
                                ) { if ready { answer() } }
                            }
                        }
                    }
                }
            }
            .frame(maxHeight: 310)

            HStack(spacing: 8) {
                Spacer(minLength: 0)
                OctetButton(title: "Skip", kind: .secondary, compact: true) {
                    session.rejectQuestion(question)
                }
                .keyboardShortcut(.cancelAction)
                OctetButton(title: "Answer", kind: .primary, compact: true) { answer() }
                    .keyboardShortcut(.defaultAction)
                    .disabled(!ready)
            }
        }
        .onAppear {
            let text = question.items.first?.question ?? "The agent needs an answer."
            AccessibilityNotification.Announcement("\(session.engine.displayName) asks: \(text)").post()
        }
    }

    private func optionRow(
        _ option: OpenCodeQuestion.Item.Option,
        item: OpenCodeQuestion.Item,
        index: Int
    ) -> some View {
        let selected = picked[index]?.contains(option.label) == true
        return Button {
            var values = picked[index] ?? []
            if item.multiple {
                if selected { values.remove(option.label) } else { values.insert(option.label) }
            } else {
                values = selected ? [] : [option.label]
            }
            picked[index] = values
        } label: {
            HStack(alignment: .top, spacing: 8) {
                RoundedRectangle(cornerRadius: item.multiple ? 3 : 7)
                    .strokeBorder(selected ? Theme.accent : Theme.border, lineWidth: 1.5)
                    .background(RoundedRectangle(cornerRadius: item.multiple ? 3 : 7)
                        .fill(selected ? Theme.accent.opacity(0.3) : .clear))
                    .frame(width: 14, height: 14)
                    .padding(.top, 1)
                VStack(alignment: .leading, spacing: 1) {
                    Text(option.label).font(Theme.uiFont).foregroundStyle(Theme.textPrimary)
                    if !option.description.isEmpty {
                        Text(option.description)
                            .font(Theme.captionFont)
                            .foregroundStyle(Theme.textTertiary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 6)
            .background(RoundedRectangle(cornerRadius: 6).fill(selected ? Theme.hover : .clear))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(selected ? .isSelected : [])
    }

    private var answers: [[String]] {
        question.items.indices.map { index in
            let text = (typed[index] ?? question.items[index].initial).trimmingCharacters(in: .whitespacesAndNewlines)
            let selected = question.items[index].options.map(\.label).filter {
                picked[index]?.contains($0) == true
            }
            return text.isEmpty ? selected : selected + [text]
        }
    }

    private var ready: Bool { answers.allSatisfy { !$0.isEmpty } }

    private func answer() {
        guard ready else { return }
        session.answerQuestion(question, answers: answers)
    }
}

private struct QuickAnswerShell<Content: View>: View {
    let agent: String
    let title: String
    var context: String?
    @ViewBuilder let content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: 11) {
            HStack(spacing: 8) {
                if let brand = AgentBrand.forAgent(agent) { AgentLogo(brand: brand, size: 13) }
                Text(title).font(Theme.uiFontMedium).foregroundStyle(Theme.textPrimary)
                Text("NEEDS YOUR ANSWER")
                    .font(Theme.headerFont)
                    .kerning(0.35)
                    .foregroundStyle(Theme.accent)
                Spacer(minLength: 0)
            }
            if let context, !context.isEmpty, context != title {
                Text(context)
                    .font(Theme.captionFont)
                    .foregroundStyle(Theme.textTertiary)
                    .lineLimit(1)
            }
            content
        }
        .padding(13)
        .frame(width: 390, alignment: .leading)
        .background(Theme.card)
        .overlay(RoundedRectangle(cornerRadius: 11).strokeBorder(Theme.accent.opacity(0.6), lineWidth: 1))
        .clipShape(RoundedRectangle(cornerRadius: 11))
        .shadow(color: .black.opacity(0.42), radius: 18, y: 8)
        .padding(.trailing, 14)
        .accessibilityElement(children: .contain)
    }
}

private struct QuickQuestionText: View {
    let question: String
    let detail: String

    init(_ question: String, detail: String = "") {
        self.question = question
        self.detail = detail
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(question)
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(Theme.textPrimary)
                .fixedSize(horizontal: false, vertical: true)
            if !detail.isEmpty {
                Text(detail)
                    .font(Theme.captionFont)
                    .foregroundStyle(Theme.textTertiary)
                    .lineLimit(3)
            }
        }
    }
}

/// Keeps short answer buttons on one line and stacks them when their labels
/// are longer than the corner panel.
private struct QuickChoiceFlow<Content: View>: View {
    @ViewBuilder let content: Content

    var body: some View {
        ViewThatFits(in: .horizontal) {
            HStack(spacing: 8) { content }
            VStack(alignment: .trailing, spacing: 8) { content }
                .frame(maxWidth: .infinity, alignment: .trailing)
        }
    }
}
