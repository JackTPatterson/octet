import SwiftUI

struct ContainerLogsPlane: View {
    let context: String
    let containerID: String
    let name: String
    let visible: Bool
    @State private var logs = ""
    @State private var failure: String?
    @State private var loading = false
    @State private var follow = true
    @State private var tail = 200
    @State private var refresh = 0
    @State private var updated: Date?
    @State private var request = UUID()

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Text(name).font(Theme.uiFontMedium).lineLimit(1)
                Spacer()
                if loading { ProgressView().controlSize(.small) }
                OctetIconButton(icon: follow ? "pause.circle" : "play.circle", help: follow ? "Pause log refresh" : "Resume log refresh", active: follow) { follow.toggle() }
                OctetIconButton(icon: "arrow.clockwise", help: "Refresh logs") { refresh += 1 }.disabled(loading)
                OctetIconButton(icon: "doc.on.doc", help: "Copy displayed logs") {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(logs, forType: .string)
                }.disabled(logs.isEmpty)
            }.padding(.horizontal, 12).frame(height: 36)
            HStack {
                Text(context.isEmpty ? "Current context" : context).font(Theme.captionFont).foregroundStyle(Theme.textSecondary).lineLimit(1)
                Spacer()
                OctetSelect(selection: $tail, options: [(100, "100 lines"), (200, "200 lines"), (500, "500 lines"), (1000, "1,000 lines")], width: 112)
                    .accessibilityLabel("Lines to show")
            }.padding(.horizontal, 12).padding(.bottom, 8)
            Divider()
            if let failure, !logs.isEmpty {
                Text(failure).font(Theme.captionFont).foregroundStyle(Theme.danger).textSelection(.enabled).padding(12)
            }
            if logs.isEmpty && !loading, let failure {
                OctetErrorState(title: "Couldn't load logs",
                                reason: "The container may have been removed or its log driver may not support reading.",
                                actionTitle: "Try Again", action: { Task { await load() } }, details: failure)
            } else if logs.isEmpty && !loading {
                PlaneMessage(icon: "tool.read", title: "No logs yet", detail: "Output written by this container will appear here.")
            } else {
                ContainerLogTextView(logs: logs, follow: follow)
            }
            HStack {
                Text(follow ? "Auto refresh · 3s" : "Refresh paused")
                Spacer()
                if let updated { Text(updated.formatted(date: .omitted, time: .standard)) }
            }.font(Theme.captionFont).foregroundStyle(Theme.textTertiary).padding(.horizontal, 12).frame(height: 26)
        }
        .background(Theme.sidebar).frame(maxWidth: .infinity, maxHeight: .infinity)
        .task(id: "\(visible):\(context):\(containerID):\(tail):\(follow):\(refresh)") {
            guard visible else { return }
            repeat {
                await load()
                guard follow, !Task.isCancelled else { return }
                do { try await Task.sleep(for: .seconds(3)) } catch { return }
            } while !Task.isCancelled
        }
    }

    @MainActor private func load() async {
        let token = UUID()
        request = token
        loading = true
        let result = await DockerCommand.run(context: context, ["logs", "--tail", String(tail), "--timestamps", containerID], mergeErrors: true)
        guard request == token else { return }
        loading = false
        guard !Task.isCancelled else { return }
        guard result.status == 0 else { failure = result.failure; return }
        logs = result.text + (result.truncated ? "\n[Output limited to 1 MB. Select fewer lines to narrow the output.]" : "")
        failure = nil
        updated = Date()
    }
}
