import SwiftUI

// The pull request plane's extras: the reviewer picker, reactions on
// comments, and the stack header. The label picker is with the Summary tab.

// MARK: - Reviewer picker

/// People and teams a review can be asked of, ticked when already asked.
struct PullRequestReviewerPicker: View {
    @ObservedObject var model: PullRequestPlaneModel
    let detail: PullRequestDetail
    @State private var query = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            OctetTextField(placeholder: "Search people and teams", text: $query) { requestTyped() }
            if let candidates = model.reviewCandidates {
                let shown = options(candidates)
                ScrollView {
                    VStack(alignment: .leading, spacing: 1) {
                        ForEach(shown) { target in
                            ReviewerRow(target: target, on: model.hasRequested(target)) { model.toggleReviewer(target) }
                        }
                        if let typed = typedLogin {
                            Button { requestTyped() } label: {
                                Text("Request @\(typed)")
                                    .font(Theme.uiFont)
                                    .foregroundStyle(Theme.accent)
                                    .padding(.horizontal, 6)
                                    .frame(maxWidth: .infinity, minHeight: 26, alignment: .leading)
                                    .contentShape(Rectangle())
                            }
                            .buttonStyle(.plain)
                        } else if shown.isEmpty {
                            Text("No matching people or teams.")
                                .font(Theme.captionFont)
                                .foregroundStyle(Theme.textTertiary)
                                .padding(6)
                        }
                    }
                }
                .frame(maxHeight: 280)
                .octetScrollIndicators()
            } else {
                Text("Reading reviewers…")
                    .font(Theme.captionFont)
                    .foregroundStyle(Theme.textTertiary)
                    .padding(6)
            }
        }
        .padding(10)
        .frame(width: 260)
        .background(Theme.card)
    }

    /// Everyone asked already, then the rest, people before teams.
    private func options(_ candidates: [PullRequestReviewTarget]) -> [PullRequestReviewTarget] {
        let asked = detail.reviewTargets
        let rest = candidates.filter { candidate in !asked.contains { $0.id == candidate.id } }
        return Self.ordered(asked + rest).filter { $0.matches(query) && $0.name.lowercased() != detail.author.lowercased() }
    }

    static func ordered(_ targets: [PullRequestReviewTarget]) -> [PullRequestReviewTarget] {
        targets.filter { !$0.isTeam } + targets.filter(\.isTeam)
    }

    /// A name typed that the list doesn't have, for someone it couldn't list.
    private var typedLogin: String? {
        let login = query.trimmingCharacters(in: .whitespaces).trimmingCharacters(in: CharacterSet(charactersIn: "@"))
        guard !login.isEmpty, !login.contains(" ") else { return nil }
        let known = (model.reviewCandidates ?? []) + detail.reviewTargets
        return known.contains { $0.name.lowercased() == login.lowercased() } ? nil : login
    }

    private func requestTyped() {
        guard let typedLogin else { return }
        model.addReviewer(typedLogin)
        query = ""
    }

    private struct ReviewerRow: View {
        let target: PullRequestReviewTarget
        let on: Bool
        let toggle: () -> Void
        @State private var hovered = false

        var body: some View {
            Button(action: toggle) {
                HStack(spacing: 8) {
                    OctetIcon("check", size: 12)
                        .foregroundStyle(Theme.accent)
                        .opacity(on ? 1 : 0)
                    if target.isTeam {
                        OctetIcon("person.2", size: 12)
                            .foregroundStyle(Theme.textTertiary)
                            .frame(width: 16, height: 16)
                    } else {
                        GitHubAvatar(login: target.name, size: 16)
                    }
                    Text(target.name)
                        .font(Theme.uiFont)
                        .foregroundStyle(Theme.textPrimary)
                        .lineLimit(1)
                    Spacer(minLength: 0)
                    if target.isTeam {
                        Text("Team").font(Theme.captionFont).foregroundStyle(Theme.textTertiary)
                    }
                }
                .padding(.horizontal, 6)
                .frame(height: 26)
                .background(RoundedRectangle(cornerRadius: Theme.rowRadius).fill(hovered ? Theme.hover : .clear))
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .onHover { hovered = $0 }
            .accessibilityAddTraits(on ? [.isButton, .isSelected] : .isButton)
        }
    }
}

// MARK: - Reactions

/// Reaction counts as small pills under a comment, and a picker to add one.
struct PullRequestReactionBar: View {
    @ObservedObject var model: PullRequestPlaneModel
    let subjectId: String
    let reactions: [PullRequestReactionCount]
    @State private var picking = false

    var body: some View {
        FlowLayout(spacing: 4) {
            ForEach(reactions) { group in
                Pill(group: group) { model.toggleReaction(group.reaction, on: subjectId) }
            }
            OctetIconButton(icon: "face.smiling", help: "Add a reaction", compact: true) { picking = true }
                .popover(isPresented: $picking, arrowEdge: .bottom) { picker }
        }
    }

    private var picker: some View {
        HStack(spacing: 2) {
            ForEach(PullRequestReaction.allCases) { reaction in
                let mine = reactions.first { $0.reaction == reaction }?.mine ?? false
                Button {
                    model.toggleReaction(reaction, on: subjectId)
                    picking = false
                } label: {
                    Text(reaction.emoji)
                        .font(.system(size: 15))
                        .frame(width: 28, height: 28)
                        .background(RoundedRectangle(cornerRadius: Theme.controlRadius).fill(mine ? Theme.cardSelected : .clear))
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .help(reaction.title)
                .accessibilityLabel(reaction.title)
                .accessibilityAddTraits(mine ? .isSelected : [])
            }
        }
        .padding(6)
        .background(Theme.card)
    }

    private struct Pill: View {
        let group: PullRequestReactionCount
        let toggle: () -> Void

        var body: some View {
            Button(action: toggle) {
                HStack(spacing: 4) {
                    Text(group.reaction.emoji).font(.system(size: 11))
                    Text("\(group.count)")
                        .font(Theme.captionFont.weight(.medium).monospacedDigit())
                        .foregroundStyle(group.mine ? Theme.accent : Theme.textSecondary)
                }
                .padding(.horizontal, 7)
                .frame(height: 20)
                .background(Capsule().fill(group.mine ? Theme.accent.opacity(0.16) : Theme.card))
                .overlay(Capsule().strokeBorder(group.mine ? Theme.accent.opacity(0.5) : Theme.border.opacity(0.6), lineWidth: 1))
                .contentShape(Capsule())
            }
            .buttonStyle(.plain)
            .help(group.mine ? "Take back \(group.reaction.title)" : group.reaction.title)
            .accessibilityLabel("\(group.reaction.title), \(group.count)")
            .accessibilityAddTraits(group.mine ? [.isButton, .isSelected] : .isButton)
        }
    }
}

// MARK: - Stack

/// "Stack 2 of 3" under the branches when this pull request is based on
/// another open one's branch, with a step each way and the whole chain in a popover.
struct PullRequestStackBar: View {
    @ObservedObject var model: PullRequestPlaneModel
    let stack: PullRequestStack
    @State private var open = false
    @State private var hovered = false

    var body: some View {
        HStack(spacing: 4) {
            Button { open.toggle() } label: {
                HStack(spacing: 5) {
                    OctetIcon("square.stack.3d.up", size: 12)
                    Text("Stack \(stack.position) of \(stack.size)")
                        .font(Theme.captionFont.weight(.medium))
                        .lineLimit(1)
                }
                .foregroundStyle(hovered || open ? Theme.textPrimary : Theme.textSecondary)
                .padding(.horizontal, 6)
                .frame(height: 22)
                .background(RoundedRectangle(cornerRadius: 5).fill(hovered || open ? Theme.hover : .clear))
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .onHover { hovered = $0 }
            .help("Pull requests stacked on each other, bottom first")
            .popover(isPresented: $open, arrowEdge: .bottom) { popover }
            Spacer(minLength: 4)
            OctetIconButton(icon: "arrow.down", help: stack.below.map { "Open #\($0.number), below" } ?? "Nothing below", compact: true) {
                if let below = stack.below { model.show(below) }
            }
            .disabled(stack.below == nil)
            OctetIconButton(icon: "arrow.up", help: stack.above.map { "Open #\($0.number), above" } ?? "Nothing above", compact: true) {
                if let above = stack.above { model.show(above) }
            }
            .disabled(stack.above == nil)
        }
    }

    /// Top of the stack first, as a stack reads, ending on the trunk.
    private var popover: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text("Stack of \(stack.size)").font(Theme.uiFontMedium).foregroundStyle(Theme.textPrimary)
                .padding(.bottom, 4)
            ForEach(Array(stack.layers.enumerated().reversed()), id: \.element.id) { index, layer in
                LayerRow(layer: layer, current: index == stack.index) {
                    open = false
                    if index != stack.index { model.show(layer) }
                }
            }
            HStack(spacing: 6) {
                OctetIcon("branch", size: 11)
                Text(stack.trunk).font(Theme.monoFont).lineLimit(1)
            }
            .foregroundStyle(Theme.textTertiary)
            .padding(.top, 4)
            .padding(.horizontal, 6)
        }
        .padding(10)
        .frame(width: 300)
        .background(Theme.card)
    }

    private struct LayerRow: View {
        let layer: PullRequestStackLayer
        let current: Bool
        let select: () -> Void
        @State private var hovered = false

        var body: some View {
            Button(action: select) {
                HStack(spacing: 8) {
                    OctetIcon(layer.tone.icon, size: 12).foregroundStyle(layer.tone.color)
                    VStack(alignment: .leading, spacing: 1) {
                        Text(layer.title.isEmpty ? layer.headRefName : layer.title)
                            .font(current ? Theme.uiFontMedium : Theme.uiFont)
                            .foregroundStyle(Theme.textPrimary)
                            .lineLimit(1)
                        Text(verbatim: "#\(layer.number) · \(layer.headRefName)")
                            .font(Theme.captionFont)
                            .foregroundStyle(Theme.textTertiary)
                            .lineLimit(1)
                    }
                    Spacer(minLength: 0)
                    if current { OctetIcon("check", size: 12).foregroundStyle(Theme.accent) }
                }
                .padding(.horizontal, 6)
                .frame(minHeight: 36)
                .background(RoundedRectangle(cornerRadius: Theme.rowRadius).fill(hovered || current ? Theme.hover : .clear))
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .onHover { hovered = $0 }
            .accessibilityAddTraits(current ? [.isButton, .isSelected] : .isButton)
        }
    }
}
