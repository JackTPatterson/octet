import AppKit
import Combine
import Network
import SwiftUI

/// The Pair a Mac dialog's state: which step it's on, the code waiting for
/// an answer, and the pairing under way. Both sides of a pairing land here:
/// the Mac that asked and the one asked each show the same code, large, and
/// say how it ended, after T3 Code's Add Environment dialog.
@MainActor
final class PeerPairingModel: ObservableObject {
    static let shared = PeerPairingModel()

    @Published private(set) var step: PeerPairingStep = .choose
    @Published private(set) var isPresented = false
    @Published var address = ""

    /// The answer the node is waiting on for the code shown.
    private var answer: (@Sendable (Bool) -> Void)?
    /// Codes that arrived while another was being compared, shown next.
    private var queued: [(machine: String, code: String, fingerprint: String, incoming: Bool, answer: @Sendable (Bool) -> Void)] = []
    private var watch: AnyCancellable?
    private var timeout: DispatchWorkItem?

    func present(_ start: PeerPairingStep = .choose) {
        if !isPresented || step.isFinished { step = start }
        isPresented = true
        PeerPairingPanel.show(model: self)
    }

    func dismiss() {
        // Closing on a code counts as "Don't Pair", so the node isn't left waiting.
        if step.awaitsAnswer { answer?(false) }
        answer = nil
        watch = nil
        timeout?.cancel()
        isPresented = false
        PeerPairingPanel.close()
        step = .choose
        address = ""
        if !queued.isEmpty {
            let next = queued.removeFirst()
            receivedCode(machine: next.machine, code: next.code, fingerprint: next.fingerprint,
                         incoming: next.incoming, answer: next.answer)
        }
    }

    func startOver() {
        move(.choose)
    }

    // MARK: Starting a pairing

    func pair(with found: DiscoveredPeer) {
        move(.connecting(machine: found.name))
        PeerCenter.shared.pair(with: found.endpoint, name: found.name) { [weak self] error in
            self?.finish(machine: found.name, error: error)
        }
    }

    func pairAddress() {
        let text = address.trimmingCharacters(in: .whitespaces)
        guard !text.isEmpty else { return }
        let host = text.split(separator: ":").dropLast().joined(separator: ":")
            .trimmingCharacters(in: CharacterSet(charactersIn: "[]"))
        move(.connecting(machine: host.isEmpty ? text : host))
        PeerCenter.shared.pair(address: text) { [weak self] error in
            self?.finish(machine: nil, error: error)
        }
    }

    // MARK: The code

    /// A code to compare, from either side; opens the dialog if it's closed.
    func receivedCode(machine: String, code: String, fingerprint: String, incoming: Bool,
                      answer: @escaping @Sendable (Bool) -> Void) {
        if case .confirm = step, isPresented {
            queued.append((machine, code, fingerprint, incoming, answer))
            return
        }
        self.answer = answer
        if !isPresented { present(.choose) }
        move(step.receivedCode(machine: machine, code: code, fingerprint: fingerprint, incoming: incoming))
    }

    func answerCode(_ accept: Bool) {
        guard case .confirm(let machine, _, let fingerprint, let incoming) = step else { return }
        let reply = answer
        answer = nil
        move(step.answered(accept))
        reply?(accept)
        guard accept else { return }
        if incoming {
            // The Mac asked has no completion to hear from: it's paired once
            // that key shows up among the paired Macs.
            watch = PeerCenter.shared.$paired
                .receive(on: RunLoop.main)
                .sink { [weak self] peers in
                    guard let self, peers.contains(where: { $0.fingerprint == fingerprint }) else { return }
                    self.finish(machine: machine, error: nil)
                }
        }
        let work = DispatchWorkItem { [weak self] in
            guard let self, case .waiting = self.step else { return }
            self.finish(machine: machine, error: "\(machine) didn't confirm in time.")
        }
        timeout = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 90, execute: work)
    }

    private func finish(machine: String?, error: String?) {
        guard isPresented, !step.isFinished, step != .choose else { return }
        watch = nil
        timeout?.cancel()
        // A failure before any code clears a code that never came.
        answer = nil
        move(step.finished(machine: machine, error: error))
    }

    private func move(_ next: PeerPairingStep) {
        MotionPreferences.shared.perform(.connections, .smooth(duration: 0.22)) { step = next }
    }

    #if DEBUG
    /// Opens straight onto `step`, for the verification hooks.
    func showSample(_ sample: PeerPairingStep) {
        isPresented = true
        step = sample
        PeerPairingPanel.show(model: self)
    }
    #endif
}

/// The dialog's window: borderless and clear, so the card draws its own
/// glass and shadow, floated over whichever Octet window is in front. A
/// window of its own, so it works the same from Settings, the Peer window
/// or a pairing request that arrives while neither is open.
@MainActor
enum PeerPairingPanel {
    private final class Panel: NSPanel {
        override var canBecomeKey: Bool { true }
        override var canBecomeMain: Bool { false }
    }

    private static var panel: NSPanel?

    static func show(model: PeerPairingModel) {
        let host = NSApp.keyWindow.flatMap { $0 === panel ? nil : $0 } ?? NSApp.mainWindow
            ?? NSApp.windows.first { $0.isVisible && $0 !== panel && $0.level == .normal }
        if panel == nil {
            let created = Panel(contentRect: NSRect(x: 0, y: 0, width: 520, height: 480),
                                styleMask: [.borderless], backing: .buffered, defer: false)
            created.isOpaque = false
            created.backgroundColor = .clear
            created.hasShadow = false
            created.isReleasedWhenClosed = false
            created.isMovableByWindowBackground = true
            created.level = .floating
            created.contentViewController = NSHostingController(rootView: PeerPairingDialog(model: model))
            panel = created
        }
        guard let panel else { return }
        if let host {
            let frame = host.frame
            panel.setFrameOrigin(NSPoint(x: frame.midX - panel.frame.width / 2, y: frame.midY - panel.frame.height / 2 + 40))
            if panel.parent == nil, host !== panel { host.addChildWindow(panel, ordered: .above) }
        } else {
            panel.center()
        }
        NSApp.activate(ignoringOtherApps: true)
        panel.makeKeyAndOrderFront(nil)
    }

    static func close() {
        guard let panel else { return }
        panel.parent?.removeChildWindow(panel)
        panel.orderOut(nil)
    }
}

/// Pair a Mac: choose a Mac, compare the code both screens show, paired.
struct PeerPairingDialog: View {
    @ObservedObject var model: PeerPairingModel
    @ObservedObject private var center = PeerCenter.shared
    @ObservedObject private var motion = MotionPreferences.shared

    var body: some View {
        VStack(spacing: 0) {
            if model.isPresented {
                card
                    .transition(motion.animates(.connections)
                        ? .opacity.combined(with: .scale(scale: 0.97)) : .identity)
            }
        }
        .frame(width: 520, height: 480)
        .animation(motion.animation(.connections, .smooth(duration: 0.18)), value: model.isPresented)
    }

    private var card: some View {
        VStack(alignment: .leading, spacing: 14) {
            header
            stages
            Group {
                switch model.step {
                case .choose: choose
                case .connecting(let machine): connecting(machine)
                case .confirm(let machine, let code, let fingerprint, let incoming):
                    confirm(machine: machine, code: code, fingerprint: fingerprint, incoming: incoming)
                case .waiting(let machine): waiting(machine)
                case .paired(let machine): paired(machine)
                case .failed(let machine, let reason): failed(machine: machine, reason: reason)
                }
            }
            .id(stepKey)
            .transition(motion.animates(.connections) ? .opacity.combined(with: .offset(y: 4)) : .identity)
        }
        .padding(18)
        .frame(width: 440, alignment: .topLeading)
        .octetGlass(cornerRadius: 18, fill: Theme.card)
        .onExitCommand { model.dismiss() }
        .frame(maxHeight: .infinity, alignment: .center)
    }

    /// Changes only when the step does, so typing doesn't replay the transition.
    private var stepKey: String {
        switch model.step {
        case .choose: "choose"
        case .connecting: "connecting"
        case .confirm(_, let code, _, _): "confirm-\(code)"
        case .waiting: "waiting"
        case .paired: "paired"
        case .failed: "failed"
        }
    }

    private var header: some View {
        HStack(spacing: 8) {
            Text(model.step.machine.map { title(for: $0) } ?? "Pair a Mac")
                .font(.system(size: 14, weight: .semibold))
                .foregroundStyle(Theme.textPrimary)
                .lineLimit(1)
            Spacer(minLength: 8)
            OctetIconButton(icon: "xmark", help: "Close") { model.dismiss() }
        }
    }

    private func title(for machine: String) -> String {
        if case .confirm(_, _, _, true) = model.step { return "\(machine) Wants to Pair" }
        return "Pair with \(machine)"
    }

    /// Three straight segments under the title, filled up to this stage.
    private var stages: some View {
        HStack(spacing: 6) {
            ForEach(Array(PeerPairingStep.stages.enumerated()), id: \.offset) { index, name in
                let reached = index <= model.step.stage
                let failed: Bool = { if case .failed = model.step { return index == 2 }; return false }()
                VStack(alignment: .leading, spacing: 5) {
                    Rectangle()
                        .fill(failed ? Theme.danger : reached ? Theme.accent : Theme.border)
                        .frame(height: 2)
                    Text(failed ? "Not Paired" : name)
                        .font(.system(size: 10.5, weight: index == model.step.stage ? .medium : .regular))
                        .foregroundStyle(index == model.step.stage ? Theme.textPrimary : Theme.textTertiary)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .accessibilityElement(children: .combine)
                .accessibilityAddTraits(index == model.step.stage ? .isSelected : [])
            }
        }
        .animation(motion.animation(.connections, .easeOut(duration: 0.2)), value: model.step.stage)
    }

    // MARK: Steps

    private var choose: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Open Octet on the other Mac with Other Macs on. Macs on this network show up here; for one on your tailnet, type its address.")
                .font(.system(size: 11.5))
                .foregroundStyle(Theme.textTertiary)
                .fixedSize(horizontal: false, vertical: true)
            VStack(spacing: 0) {
                if center.nearby.isEmpty {
                    HStack(spacing: 8) {
                        ProgressView().controlSize(.small)
                        Text("Looking for Macs on this network…").font(Theme.uiFont).foregroundStyle(Theme.textSecondary)
                        Spacer()
                    }
                    .padding(.horizontal, 12)
                    .frame(height: 40)
                }
                ForEach(Array(center.nearby.enumerated()), id: \.element.id) { index, found in
                    if index > 0 { SettingsDivider() }
                    HStack(spacing: 9) {
                        PeerMachineIcon(name: found.name)
                        Text(found.name).font(Theme.uiFontMedium).foregroundStyle(Theme.textPrimary).lineLimit(1)
                        PeerChip(text: "Nearby")
                        Spacer(minLength: 6)
                        OctetButton(title: "Pair", kind: .secondary, compact: true) { model.pair(with: found) }
                    }
                    .padding(.horizontal, 12)
                    .frame(height: 40)
                }
            }
            .background(Theme.terminalBackground.opacity(0.35))
            .overlay(RoundedRectangle(cornerRadius: 10).strokeBorder(Theme.border.opacity(0.7), lineWidth: 1))
            .clipShape(RoundedRectangle(cornerRadius: 10))
            VStack(alignment: .leading, spacing: 6) {
                Text("Or by address").font(Theme.captionFont.weight(.medium)).foregroundStyle(Theme.textSecondary)
                HStack(spacing: 6) {
                    OctetTextField(placeholder: "studio.local:52100", text: $model.address) { model.pairAddress() }
                    OctetButton(title: "Connect", kind: .primary) { model.pairAddress() }
                        .disabled(model.address.trimmingCharacters(in: .whitespaces).isEmpty)
                }
            }
            thisMac
        }
    }

    /// What to pick or type on the other Mac to pair from there instead.
    private var thisMac: some View {
        HStack(spacing: 6) {
            Text("This Mac:").font(Theme.captionFont).foregroundStyle(Theme.textTertiary)
            Text(center.machineName).font(Theme.captionFont.weight(.medium)).foregroundStyle(Theme.textSecondary).lineLimit(1)
            if let address = center.address {
                OctetCopyText(text: address, help: "Copy this Mac's address")
            }
            Spacer(minLength: 0)
        }
    }

    private func connecting(_ machine: String) -> some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(spacing: 10) {
                ProgressView().controlSize(.small)
                Text("Connecting to \(machine)…").font(Theme.uiFont).foregroundStyle(Theme.textSecondary)
            }
            .frame(maxWidth: .infinity, minHeight: 120)
            footer {
                OctetButton(title: "Cancel", kind: .secondary) { model.dismiss() }
            }
        }
    }

    private func confirm(machine: String, code: String, fingerprint: String, incoming: Bool) -> some View {
        VStack(alignment: .leading, spacing: 14) {
            Text(incoming ? "Pair only if \(machine) shows this same code." : "Check that \(machine) shows this same code.")
                .font(Theme.uiFont)
                .foregroundStyle(Theme.textSecondary)
            codeBlock(code, fingerprint: fingerprint, dimmed: false)
            Text("A paired Mac can see your agents here, and message them or give them tasks as you allow in Settings › Other Macs.")
                .font(.system(size: 11.5))
                .foregroundStyle(Theme.textTertiary)
                .fixedSize(horizontal: false, vertical: true)
            footer {
                OctetButton(title: "Don't Pair", kind: .secondary) { model.answerCode(false) }
                    .keyboardShortcut(.cancelAction)
                OctetButton(title: "Codes Match, Pair", kind: .primary) { model.answerCode(true) }
                    .keyboardShortcut(.defaultAction)
            }
        }
    }

    private func waiting(_ machine: String) -> some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(spacing: 10) {
                ProgressView().controlSize(.small)
                Text("Waiting for \(machine) to confirm the code…").font(Theme.uiFont).foregroundStyle(Theme.textSecondary)
            }
            .frame(maxWidth: .infinity, minHeight: 120)
            footer {
                OctetButton(title: "Cancel", kind: .secondary) { model.dismiss() }
            }
        }
    }

    private func paired(_ machine: String) -> some View {
        VStack(alignment: .leading, spacing: 14) {
            outcome(icon: "checkmark.circle.fill", tint: Color(hex: AgentStateColor.done), title: "Paired with \(machine)",
                    message: "Agents here can now reach agents on \(machine). It asks before anything reaches an agent here; change that in its trust setting.")
            footer {
                OctetButton(title: "Show Its Agents", kind: .secondary) {
                    PeerPanelModel.shared.focusMachine = machine
                    model.dismiss()
                    PeerWindow.show()
                }
                OctetButton(title: "Done", kind: .primary) { model.dismiss() }
                    .keyboardShortcut(.defaultAction)
            }
        }
    }

    private func failed(machine: String?, reason: String) -> some View {
        VStack(alignment: .leading, spacing: 14) {
            outcome(icon: "exclamationmark.triangle.fill", tint: Theme.danger,
                    title: machine.map { "Couldn't Pair with \($0)" } ?? "Couldn't Pair", message: reason)
            footer {
                OctetButton(title: "Close", kind: .secondary) { model.dismiss() }
                    .keyboardShortcut(.cancelAction)
                OctetButton(title: "Try Again", kind: .primary) { model.startOver() }
                    .keyboardShortcut(.defaultAction)
            }
        }
    }

    // MARK: Parts

    /// The code, large and monospaced so each digit can be read across a desk.
    private func codeBlock(_ code: String, fingerprint: String, dimmed: Bool) -> some View {
        VStack(spacing: 6) {
            Text(code)
                .font(.system(size: 40, weight: .semibold, design: .monospaced))
                .kerning(4)
                .foregroundStyle(Theme.textPrimary)
                .textSelection(.enabled)
                .accessibilityLabel("Code \(code.map(String.init).joined(separator: " "))")
            Text("Its key \(fingerprint)")
                .font(Theme.monoFont)
                .foregroundStyle(Theme.textTertiary)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 16)
        .background(RoundedRectangle(cornerRadius: 12).fill(Theme.terminalBackground.opacity(0.55)))
        .overlay(RoundedRectangle(cornerRadius: 12).strokeBorder(Theme.border.opacity(0.7), lineWidth: 1))
        .opacity(dimmed ? 0.5 : 1)
    }

    private func outcome(icon: String, tint: Color, title: String, message: String) -> some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: icon).font(.system(size: 22)).foregroundStyle(tint)
            VStack(alignment: .leading, spacing: 4) {
                Text(title).font(.system(size: 13, weight: .semibold)).foregroundStyle(Theme.textPrimary)
                Text(message)
                    .font(Theme.uiFont)
                    .foregroundStyle(Theme.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .frame(maxWidth: .infinity, minHeight: 80, alignment: .leading)
    }

    private func footer<Buttons: View>(@ViewBuilder _ buttons: () -> Buttons) -> some View {
        HStack(spacing: 8) {
            Spacer()
            buttons()
        }
    }
}
