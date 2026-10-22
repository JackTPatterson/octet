import AppKit
import SwiftUI

/// The composer footer's icon buttons: one family of SF Symbols at one size
/// and weight, in T3 Code's 28pt ghost button, so no icon reads heavier or
/// lighter than its neighbours. `on` lights it in a tint while what it
/// stands for is running.
struct ChatSymbolButton: View {
    let symbol: String
    let help: String
    var on: Color?
    let action: () -> Void
    @State private var hovered = false
    @Environment(\.isEnabled) private var enabled

    var body: some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: 14, weight: .regular))
                .foregroundStyle(on ?? (hovered ? ChatStyle.text : ChatStyle.mutedText))
                .frame(width: 28, height: 28)
                .background(RoundedRectangle(cornerRadius: ChatStyle.controlRadius, style: .continuous)
                    .fill(on.map { $0.opacity(hovered ? 0.18 : 0.12) } ?? (hovered ? ChatStyle.hover : .clear)))
                .opacity(enabled ? 1 : 0.4)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hovered = $0 }
        .help(help)
        .accessibilityLabel(help)
    }
}

/// Remote Control in the footer: an icon that lights green while it's on,
/// opening a popover that says where it stands and does the rest (turn it
/// on, open the session on claude.ai, copy its link, turn it off).
struct RemoteControlControl: View {
    @ObservedObject var session: AgentSession
    @ObservedObject var dropdowns: OctetDropdownState

    var body: some View {
        let state = session.remoteControl
        OctetDropdownAnchor(spec: OctetDropdownSpec(id: "remote-control", options: [], selected: "", select: { _ in },
            panel: { close in AnyView(RemoteControlPanel(session: session, close: close)) }), state: dropdowns) { open in
            RemoteControlIcon(state: state, open: open)
        }
        .help(Self.help(state))
        .accessibilityLabel("Remote Control")
        .accessibilityValue(Self.status(state))
    }

    static func status(_ state: AgentSession.RemoteControl) -> String {
        switch state {
        case .off: "Off"
        case .connecting: "Connecting…"
        case .on: "On"
        case .failed: "Couldn't connect"
        }
    }

    private static func help(_ state: AgentSession.RemoteControl) -> String {
        switch state {
        case .on: "Remote Control is on: this conversation is open in claude.ai and the Claude app"
        case .connecting: "Starting Remote Control"
        default: "Remote Control: continue this conversation from claude.ai or the Claude app"
        }
    }
}

private struct RemoteControlIcon: View {
    let state: AgentSession.RemoteControl
    let open: Bool
    @State private var hovered = false

    var body: some View {
        let tint: Color? = switch state {
        case .on: ChatStyle.added
        case .connecting: ChatStyle.secondaryText
        case .failed: ChatStyle.warning
        case .off: nil
        }
        Image(systemName: "antenna.radiowaves.left.and.right")
            .font(.system(size: 14, weight: .regular))
            .symbolEffect(.variableColor.iterative, isActive: state == .connecting)
            .foregroundStyle(tint ?? (hovered || open ? ChatStyle.text : ChatStyle.mutedText))
            .frame(width: 28, height: 28)
            .background(RoundedRectangle(cornerRadius: ChatStyle.controlRadius, style: .continuous)
                .fill(tint.map { $0.opacity(hovered || open ? 0.18 : 0.12) } ?? (hovered || open ? ChatStyle.hover : .clear)))
            .overlay(alignment: .topTrailing) {
                if case .on = state {
                    Circle().fill(ChatStyle.added).frame(width: 5, height: 5).offset(x: -4, y: 4)
                }
            }
            .contentShape(Rectangle())
            .onHover { hovered = $0 }
    }
}

private struct RemoteControlPanel: View {
    @ObservedObject var session: AgentSession
    let close: () -> Void
    @Environment(\.openURL) private var openURL

    var body: some View {
        let state = session.remoteControl
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 8) {
                Image(systemName: "antenna.radiowaves.left.and.right")
                    .font(.system(size: 14))
                    .foregroundStyle(ChatStyle.secondaryText)
                Text("Remote Control").font(Theme.interfaceFont(13, weight: .semibold)).foregroundStyle(ChatStyle.text)
                Spacer(minLength: 8)
                StatusPill(state: state)
            }
            Text("Continue this conversation from claude.ai or the Claude app. Messages sent there show up here, and replies go both ways.")
                .font(ChatStyle.meta)
                .foregroundStyle(ChatStyle.secondaryText)
                .fixedSize(horizontal: false, vertical: true)
            if case .on(let url?) = state {
                HStack(spacing: 6) {
                    Image(systemName: "link").font(.system(size: 11)).foregroundStyle(ChatStyle.mutedText)
                    Text(url.absoluteString)
                        .font(Theme.Text.mono(11))
                        .foregroundStyle(ChatStyle.secondaryText)
                        .lineLimit(1)
                        .truncationMode(.middle)
                        .textSelection(.enabled)
                }
                .padding(.horizontal, 8)
                .frame(height: 28)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(RoundedRectangle(cornerRadius: ChatStyle.controlRadius, style: .continuous).fill(ChatStyle.page.opacity(0.6)))
                .overlay(RoundedRectangle(cornerRadius: ChatStyle.controlRadius, style: .continuous).strokeBorder(ChatStyle.border, lineWidth: 1))
            }
            if case .failed(let reason) = state {
                HStack(alignment: .top, spacing: 6) {
                    Image(systemName: "exclamationmark.triangle.fill").font(.system(size: 11))
                    Text(reason).font(ChatStyle.meta).fixedSize(horizontal: false, vertical: true)
                }
                .foregroundStyle(ChatStyle.warning)
            }
            HStack(spacing: 6) {
                switch state {
                case .off:
                    Spacer(minLength: 0)
                    ChatButton(title: "Turn On", kind: .primary) { session.setRemoteControl(true) }
                case .failed:
                    Spacer(minLength: 0)
                    ChatButton(title: "Try Again", kind: .primary) { session.setRemoteControl(true) }
                case .connecting:
                    ProgressView().controlSize(.small)
                    Text("Connecting…").font(ChatStyle.meta).foregroundStyle(ChatStyle.mutedText)
                    Spacer(minLength: 0)
                    ChatButton(title: "Cancel", kind: .ghost) { session.setRemoteControl(false) }
                case .on(let url):
                    ChatButton(title: "Turn Off", kind: .ghost) { session.setRemoteControl(false); close() }
                    Spacer(minLength: 0)
                    if let url {
                        ChatButton(title: "Copy Link", icon: "doc.on.doc", kind: .outline) {
                            NSPasteboard.general.clearContents()
                            NSPasteboard.general.setString(url.absoluteString, forType: .string)
                            ClipboardWatcher.shared.acknowledge()
                            ToastCenter.shared.info("Copied the Remote Control link", detail: url.absoluteString)
                        }
                        ChatButton(title: "Open in claude.ai", kind: .primary) { openURL(url); close() }
                    }
                }
            }
        }
        .padding(16)
        .frame(width: 320)
        .chatPopover()
        .animation(.easeInOut(duration: 0.2), value: state)
        .onExitCommand(perform: close)
    }
}

private struct StatusPill: View {
    let state: AgentSession.RemoteControl

    var body: some View {
        let tint: Color = switch state {
        case .on: ChatStyle.added
        case .failed: ChatStyle.warning
        default: ChatStyle.mutedText
        }
        HStack(spacing: 5) {
            Circle().fill(tint).frame(width: 6, height: 6)
            Text(RemoteControlControl.status(state))
        }
        .font(Theme.interfaceFont(11, weight: .medium))
        .foregroundStyle(tint)
        .padding(.horizontal, 7)
        .frame(height: 20)
        .background(Capsule().fill(tint.opacity(0.12)))
    }
}
