import SwiftUI

/// "Send to this agent": one line and a send button, after Orca's dashboard.
/// The hub's chosen card and the Agents tab's needs-you cards both use it;
/// what sending means is the caller's (`HubAgent.send`, a pane's prompt).
struct AgentSendField: View {
    let placeholder: String
    /// What VoiceOver calls the field: "Message to fix-login".
    let label: String
    /// Puts the cursor in the field as it appears.
    var focusOnAppear = false
    let send: (String) -> Void
    @State private var text = ""

    var body: some View {
        HStack(spacing: Theme.Space.sm) {
            OctetTextField(placeholder: placeholder, text: $text, label: label, onSubmit: submit,
                           focusRequest: focusOnAppear ? 1 : 0)
            OctetIconButton(icon: "arrow.up", help: "Send (Return)", compact: true) { submit() }
                .disabled(text.trimmingCharacters(in: .whitespaces).isEmpty)
        }
    }

    private func submit() {
        let message = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !message.isEmpty else { return }
        send(message)
        text = ""
    }
}
