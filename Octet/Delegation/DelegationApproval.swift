import AppKit
import SwiftUI

/// Asks whether an agent may hand work to another: who's asking, who it
/// asks, what the work is, and what it can touch. Queued, one at a time; an
/// unanswered request is left for the caller to time out.
@MainActor
final class DelegationApprovalCenter: ObservableObject {
    static let shared = DelegationApprovalCenter()

    struct Request: Identifiable {
        let id = UUID()
        let caller: String
        let callerAgent: String?
        let agent: String
        let agentName: String
        let mode: DelegationMode
        let task: String
        let folder: String
        var onAllow: (_ remember: Bool) -> Void
        var onDeny: () -> Void
        weak var window: NSWindow? = NSApp.keyWindow
    }

    @Published private(set) var request: Request? {
        didSet { DebugSnapshot.overlay("delegation-approval", request != nil) }
    }
    @Published var remember = false
    private var queue: [Request] = []

    func ask(_ request: Request) {
        if self.request == nil {
            remember = false
            self.request = request
        } else {
            queue.append(request)
        }
    }

    func allow() {
        guard let current = request else { return }
        let always = remember
        advance()
        current.onAllow(always)
    }

    func deny() {
        guard let current = request else { return }
        advance()
        current.onDeny()
    }

    private func advance() {
        remember = false
        request = queue.isEmpty ? nil : queue.removeFirst()
    }
}

struct DelegationApprovalDialog: View {
    @ObservedObject var center: DelegationApprovalCenter
    @ObservedObject private var motion = MotionPreferences.shared
    @StateObject private var host = HostWindow()
    @State private var copied = false

    var body: some View {
        ZStack {
            if let request = center.request, host.owns(request.window) {
                Theme.scrim.ignoresSafeArea().onTapGesture { center.deny() }
                card(request)
                    .transition(motion.animates(.palette) ? .opacity.combined(with: .scale(scale: 0.96)) : .identity)
            }
        }
        .animation(motion.animation(.palette, .smooth(duration: 0.16)), value: center.request?.id)
        .background(HostWindowReader(host: host))
    }

    private func card(_ request: DelegationApprovalCenter.Request) -> some View {
        let isReview = request.mode == .review
        return VStack(alignment: .leading, spacing: 14) {
            HStack(alignment: .center, spacing: 12) {
                HStack(spacing: 6) {
                    logoTile(request.callerAgent)
                    OctetIcon("arrow.right", size: 12).foregroundStyle(Theme.textTertiary)
                    logoTile(request.agent)
                }
                VStack(alignment: .leading, spacing: 3) {
                    Text("\(request.caller) wants \(request.agentName) to \(isReview ? "review its changes" : "work on a task")")
                        .font(Theme.interfaceFont(14, weight: .semibold))
                        .foregroundStyle(Theme.textPrimary)
                        .fixedSize(horizontal: false, vertical: true)
                    Text("In \((request.folder as NSString).abbreviatingWithTildeInPath)")
                        .font(Theme.interfaceFont(12))
                        .foregroundStyle(Theme.textTertiary)
                        .lineLimit(1)
                        .truncationMode(.head)
                }
            }
            HStack(spacing: 8) {
                pill(icon: isReview ? "lock" : "arrow.triangle.branch",
                     text: isReview ? "Read-only: it can't change files" : "Works in a worktree of its own")
                pill(icon: "terminal", text: "Runs in a new tab")
            }
            VStack(alignment: .leading, spacing: 6) {
                HStack {
                    Text("What it was asked")
                        .font(Theme.interfaceFont(11, weight: .medium))
                        .foregroundStyle(Theme.textTertiary)
                    Spacer()
                    OctetIconButton(icon: copied ? "checkmark" : "doc.on.doc", help: "Copy", compact: true) {
                        NSPasteboard.general.clearContents()
                        NSPasteboard.general.setString(request.task, forType: .string)
                        copied = true
                    }
                }
                // As tall as the task needs, scrolling past 200pt.
                ViewThatFits(in: .vertical) {
                    taskText(request.task)
                    ScrollView { taskText(request.task) }.frame(height: 200)
                }
                .background(RoundedRectangle(cornerRadius: Theme.controlRadius).fill(Theme.terminalBackground))
                .overlay(RoundedRectangle(cornerRadius: Theme.controlRadius).strokeBorder(Theme.border, lineWidth: 1))
            }
            Text("The answer goes back to \(request.caller) when it's done.")
                .font(Theme.interfaceFont(12))
                .foregroundStyle(Theme.textTertiary)
            Toggle(isReview ? "Don't ask before reviews" : "Don't ask before reviews or tasks", isOn: $center.remember)
                .toggleStyle(OctetCheckboxStyle())
            HStack(spacing: 8) {
                Spacer()
                OctetButton(title: "Deny", kind: .secondary, compact: true) { center.deny() }
                    .keyboardShortcut(.cancelAction)
                OctetButton(title: isReview ? "Review" : "Start", kind: .primary, compact: true) { center.allow() }
                    .keyboardShortcut(.defaultAction)
            }
        }
        .padding(18)
        .frame(width: 520)
        .octetGlass(cornerRadius: 18, fill: Theme.card)
        .onChange(of: request.id) { _, _ in copied = false }
        .accessibilityElement(children: .contain)
        .accessibilityLabel("\(request.caller) wants \(request.agentName) to \(isReview ? "review its changes" : "work on a task")")
    }

    private func taskText(_ task: String) -> some View {
        Text(task)
            .font(Theme.monoFont)
            .foregroundStyle(Theme.textSecondary)
            .textSelection(.enabled)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(10)
    }

    private func logoTile(_ agent: String?) -> some View {
        Group {
            if let brand = AgentBrand.forAgent(agent) {
                AgentLogo(brand: brand, size: 20)
            } else {
                OctetIcon("tool.agent", size: 18).foregroundStyle(Theme.textSecondary)
            }
        }
        .frame(width: 36, height: 36)
        .background(RoundedRectangle(cornerRadius: Theme.controlRadius).fill(Theme.cardSelected))
    }

    private func pill(icon: String, text: String) -> some View {
        HStack(spacing: 5) {
            OctetIcon(icon, size: 11)
            Text(text).lineLimit(1)
        }
        .font(Theme.interfaceFont(11.5))
        .foregroundStyle(Theme.textSecondary)
        .padding(.horizontal, 8)
        .frame(height: 22)
        .background(Capsule().fill(Theme.hover))
    }
}
