import SwiftUI

/// "Set up devices", after T3 Code's: what this Mac has for simulators and
/// emulators, AXe for smooth video and touch, and whether agents may use
/// them. Shown over the Device plane in Octet's dialog look; laid out like
/// WaitEditorSheet (heading, body, footer between dividers).
struct DeviceSetupSheet: View {
    @ObservedObject var model: DeviceHubModel
    @ObservedObject private var motion = MotionPreferences.shared
    @AppStorage(DeviceSetup.agentAccessKey) private var agentAccess = false
    @State private var step = DeviceSetup.Step.simulators

    var body: some View {
        ZStack {
            if model.setupShowing {
                Color.black.opacity(0.6)
                    .ignoresSafeArea()
                    .onTapGesture { cancel() }
                card
                    .padding(16)
                    .transition(motion.animates(.palette) ? .opacity.combined(with: .scale(scale: 0.96)) : .identity)
            }
        }
        .animation(motion.animation(.palette, .smooth(duration: 0.16)), value: model.setupShowing)
    }

    private var card: some View {
        VStack(alignment: .leading, spacing: 0) {
            VStack(alignment: .leading, spacing: 3) {
                Text("Set up devices")
                    .font(.system(size: 15, weight: .semibold)).foregroundStyle(Theme.textPrimary)
                Text("Review what this Mac needs before using simulators and emulators.")
                    .font(Theme.uiFont).foregroundStyle(Theme.textTertiary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .padding(16)
            stepper
                .padding(.horizontal, 16)
                .padding(.bottom, 12)
            Rectangle().fill(Theme.divider).frame(height: 1)
            ScrollView {
                VStack(alignment: .leading, spacing: 12) {
                    Text(step.heading)
                        .font(Theme.uiFontMedium).foregroundStyle(Theme.textPrimary)
                    switch step {
                    case .simulators: simulators
                    case .touch: touch
                    case .agent: agent
                    }
                }
                .padding(16)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .frame(maxHeight: 360)
            .fixedSize(horizontal: false, vertical: true)
            Rectangle().fill(Theme.divider).frame(height: 1)
            footer.padding(12)
        }
        .frame(maxWidth: 460)
        .background(RoundedRectangle(cornerRadius: 18).fill(Theme.chrome))
        .overlay(alignment: .top) {
            // A faint highlight along the top edge, as Octet's dialogs have.
            RoundedRectangle(cornerRadius: 18)
                .strokeBorder(LinearGradient(colors: [.white.opacity(0.04), .clear], startPoint: .top, endPoint: .center),
                              lineWidth: 1)
        }
        .overlay(RoundedRectangle(cornerRadius: 18).strokeBorder(Theme.border, lineWidth: 1))
        .clipShape(RoundedRectangle(cornerRadius: 18))
        .shadow(color: .black.opacity(0.6), radius: 36, y: 18)
        .onExitCommand { cancel() }
    }

    // MARK: Stepper

    private var stepper: some View {
        HStack(spacing: 6) {
            ForEach(DeviceSetup.Step.allCases, id: \.self) { item in
                let reached = item.rawValue <= step.rawValue
                HStack(spacing: 6) {
                    Text("\(item.rawValue + 1)")
                        .font(Theme.captionFont.monospacedDigit().weight(.semibold))
                        .foregroundStyle(item == step ? Theme.onAccent : reached ? Theme.textPrimary : Theme.textTertiary)
                        .frame(width: 18, height: 18)
                        .background(Circle().fill(item == step ? Theme.accent : Theme.card))
                    Text(item.title)
                        .font(Theme.captionFont)
                        .foregroundStyle(reached ? Theme.textPrimary : Theme.textTertiary)
                        .lineLimit(1)
                }
                if item != DeviceSetup.Step.allCases.last {
                    Rectangle().fill(reached && item != step ? Theme.accent.opacity(0.6) : Theme.divider)
                        .frame(height: 1)
                        .frame(minWidth: 8, maxWidth: .infinity)
                }
            }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Step \(step.rawValue + 1) of 3, \(step.title)")
    }

    // MARK: Steps

    @ViewBuilder private var simulators: some View {
        platformCard(title: "iOS", icon: "device.iphone", status: model.iosStatus,
                     message: DeviceSetup.iosMessage(model.iosStatus)) {
            if model.iosStatus == .noDevices {
                OctetButton(title: model.creatingIPhone ? "Creating…" : "Create iPhone Simulator", icon: "plus",
                            compact: true) { model.createIPhone() }
                    .disabled(model.creatingIPhone)
            }
        }
        platformCard(title: "Android", icon: "device.android", status: model.androidStatus,
                     message: DeviceSetup.androidMessage(model.androidStatus)) { EmptyView() }
        Text("You can use either platform. Fixing a missing platform does not block the other one.")
            .font(Theme.captionFont).foregroundStyle(Theme.textTertiary)
            .fixedSize(horizontal: false, vertical: true)
        checkAgain
    }

    @ViewBuilder private var touch: some View {
        let ready = !model.axeMissing
        statusRow(ready: ready, title: ready ? "AXe is installed." : "AXe isn't installed.")
        if !ready {
            OctetCopyText(text: "brew install cameroncooke/axe/axe")
            HStack(spacing: 8) {
                OctetButton(title: model.installingAxe ? "Installing…" : "Install with Homebrew", icon: "square.and.arrow.down",
                            kind: .primary, compact: true) { model.installAxe() }
                    .disabled(model.installingAxe)
                checkAgain
            }
        }
        Text("Without AXe the screen updates about once a second and taps don't reach the simulator.")
            .font(Theme.captionFont).foregroundStyle(Theme.textTertiary)
            .fixedSize(horizontal: false, vertical: true)
    }

    @ViewBuilder private var agent: some View {
        Toggle(isOn: $agentAccess) {
            Text("Let agents in Octet see and drive the simulators you open here.")
                .font(Theme.uiFont).foregroundStyle(Theme.textSecondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .toggleStyle(.switch)
        .controlSize(.small)
        Text(agentAccess
             ? "Send Screenshot to Agent is on in the device's controls, and the agent is told which device it's looking at."
             : "Agents won't be sent this device's screen.")
            .font(Theme.captionFont).foregroundStyle(Theme.textTertiary)
            .fixedSize(horizontal: false, vertical: true)
    }

    private var checkAgain: some View {
        OctetButton(title: model.checking ? "Checking…" : "Check Again", icon: "arrow.clockwise", compact: true) {
            Task { await model.checkAgain() }
        }
        .disabled(model.checking)
    }

    private func platformCard<Extra: View>(title: String, icon: String, status: DeviceSetup.Status, message: String,
                                           @ViewBuilder extra: () -> Extra) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                OctetIcon(icon, size: 15).foregroundStyle(Theme.textSecondary)
                Text(title).font(Theme.uiFontMedium).foregroundStyle(Theme.textPrimary)
                Spacer(minLength: 4)
                Text(status.title)
                    .font(Theme.captionFont.weight(.medium))
                    .foregroundStyle(status == .ready ? Color.green : status == .missing ? Theme.danger : Theme.textSecondary)
                    .padding(.horizontal, 7)
                    .frame(height: 18)
                    .background(Capsule().fill(Theme.hover))
            }
            Text(message)
                .font(Theme.uiFont).foregroundStyle(Theme.textSecondary)
                .fixedSize(horizontal: false, vertical: true)
            extra()
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 10).fill(Theme.card))
        .overlay(RoundedRectangle(cornerRadius: 10).strokeBorder(Theme.border, lineWidth: 1))
        .accessibilityElement(children: .combine)
    }

    private func statusRow(ready: Bool, title: String) -> some View {
        HStack(spacing: 6) {
            OctetIcon(ready ? "circle.check" : "circle.x", size: 14)
                .foregroundStyle(ready ? Color.green : Theme.textTertiary)
            Text(title).font(Theme.uiFont).foregroundStyle(Theme.textPrimary)
        }
    }

    // MARK: Footer

    private var footer: some View {
        HStack(spacing: 8) {
            OctetButton(title: "Cancel", kind: .ghost, compact: true) { cancel() }
                .keyboardShortcut(.cancelAction)
            Spacer()
            if step != .simulators {
                OctetButton(title: "Back", kind: .secondary, compact: true) { move(-1) }
            }
            if step == .agent {
                OctetButton(title: "Done", kind: .primary, compact: true) { done() }
                    .keyboardShortcut(.defaultAction)
            } else {
                OctetButton(title: "Continue", kind: .primary, compact: true) { move(1) }
                    .keyboardShortcut(.defaultAction)
            }
        }
    }

    private func move(_ by: Int) {
        guard let next = DeviceSetup.Step(rawValue: step.rawValue + by) else { return }
        motion.perform(.sidebar) { step = next }
    }

    private func cancel() {
        model.setupShowing = false
        step = .simulators
    }

    private func done() {
        UserDefaults.standard.set(true, forKey: DeviceSetup.doneKey)
        model.setupShowing = false
        step = .simulators
    }
}
