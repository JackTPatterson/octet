import SwiftUI

struct WorkspaceSetupControl: View {
    let directory: String?
    let store: SessionStore
    @ObservedObject private var setup = WorktreeSetupRunner.shared
    @State private var showing = false
    var body: some View {
        if let state = setup.state(for: directory) {
            OctetIconButton(icon: state.phase == .failed ? "exclamationmark.triangle" : state.active ? "hourglass" : "checkmark.circle",
                            help: state.title) { showing = true }
                .popover(isPresented: $showing) {
                    VStack(alignment: .leading, spacing: 10) {
                        Text(state.title).font(Theme.uiFontMedium)
                        Text(URL(fileURLWithPath: state.checkout).lastPathComponent).font(Theme.captionFont).foregroundStyle(Theme.textSecondary)
                        if !state.detail.isEmpty { Text(state.detail).font(Theme.captionFont).textSelection(.enabled) }
                        if state.active { ProgressView().controlSize(.small) }
                        HStack {
                            if let path = state.logPath {
                                OctetButton(title: "Open log", compact: true) { NSWorkspace.shared.open(URL(fileURLWithPath: path)) }
                            }
                            if !state.active {
                                OctetButton(title: "Retry setup", compact: true) { setup.retry(state.checkout, store: store) }
                            }
                        }
                    }.padding(16).frame(width: 320).foregroundStyle(Theme.textPrimary).background(Theme.chrome)
                }
        }
    }
}
