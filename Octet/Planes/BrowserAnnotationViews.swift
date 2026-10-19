import SwiftUI

struct BrowserPickerButton: View {
    @ObservedObject var annotations: BrowserAnnotations
    let available: Bool
    var body: some View {
        OctetIconButton(icon: "cursorarrow", help: annotations.picking ? "Stop selecting (Escape)" : "Select an element to annotate",
                        active: annotations.picking) { annotations.toggle() }
            .disabled(!available || annotations.capturing)
    }
}

struct BrowserAnnotationTray: View {
    @ObservedObject var annotations: BrowserAnnotations
    @EnvironmentObject private var window: WindowContext
    @ObservedObject private var center = AgentCenter.shared
    let directory: String?
    @State private var recipient = ""
    @State private var sending = false
    @State private var expanded = true
    @State private var preview: Data?

    private var sessions: [AgentSession] {
        center.sessions.filter { $0.workspaceId == window.focusedWorkspace?.workspaceId }
    }
    private var agents: [EngineAgent] {
        window.store.snapshot.agents.filter { $0.agent != nil && !$0.isSubagentViewer && $0.workspaceId == window.focusedWorkspace?.workspaceId }
    }
    private var recipients: [(value: String, title: String)] {
        sessions.map { ("chat:" + $0.id, $0.engine.displayName + " · " + $0.title) }
        + agents.map { ("pane:" + $0.paneId, DiffReviewView.name($0, in: window.store)) }
    }
    private var target: String { recipients.contains { $0.value == recipient } ? recipient : recipients.first?.value ?? "" }

    var body: some View {
        if annotations.picking || annotations.capturing || !annotations.items.isEmpty || annotations.failure != nil {
            VStack(alignment: .leading, spacing: 8) {
                HStack {
                    Button { expanded.toggle() } label: {
                        Label("Annotations · \(annotations.items.count)", systemImage: expanded ? "chevron.down" : "chevron.right")
                            .font(Theme.uiFontMedium)
                    }.buttonStyle(.plain)
                    Spacer()
                    if annotations.capturing { ProgressView().controlSize(.small) }
                    if !annotations.items.isEmpty {
                        OctetButton(title: "Clear", kind: .ghost, compact: true) { annotations.clear() }.disabled(sending)
                    }
                }
                if annotations.picking { Text("Click an element in the page. Escape stops selection.").font(Theme.captionFont) }
                if let failure = annotations.failure { Text(failure).font(Theme.captionFont).foregroundStyle(Theme.danger).textSelection(.enabled) }
                if expanded, !annotations.items.isEmpty {
                    ScrollView {
                        VStack(alignment: .leading, spacing: 10) {
                            ForEach($annotations.items) { $item in
                                HStack(alignment: .top, spacing: 8) {
                                    if let data = item.screenshot, let image = NSImage(data: data) {
                                        Button { preview = data } label: {
                                            Image(nsImage: image).resizable().scaledToFit().frame(width: 70, height: 55)
                                        }.buttonStyle(.plain).help("Preview screenshot")
                                    }
                                    VStack(alignment: .leading, spacing: 4) {
                                        Text(item.context.selector).font(Theme.captionFont).lineLimit(2).textSelection(.enabled)
                                        Text(item.context.url).font(Theme.captionFont).foregroundStyle(Theme.textTertiary).lineLimit(1)
                                        TextField("What should change?", text: $item.note, axis: .vertical)
                                            .font(Theme.uiFont).lineLimit(1...3).textFieldStyle(.plain)
                                            .padding(6).background(Theme.cardSelected)
                                            .clipShape(RoundedRectangle(cornerRadius: 5))
                                    }
                                    OctetIconButton(icon: "xmark", help: "Remove annotation", compact: true) {
                                        annotations.items.removeAll { $0.id == item.id }
                                    }.disabled(sending)
                                }
                            }
                        }
                    }.frame(height: min(190, CGFloat(annotations.items.count) * 105)).disabled(sending)
                    HStack {
                        OctetButton(title: "Copy", compact: true) {
                            NSPasteboard.general.clearContents()
                            NSPasteboard.general.setString(BrowserAnnotation.prompt(annotations.items), forType: .string)
                        }
                        if !recipients.isEmpty {
                            OctetSelect(selection: Binding(get: { target }, set: { recipient = $0 }), options: recipients)
                            OctetButton(title: sending ? "Sending…" : "Send to agent", kind: .primary, compact: true) { send() }
                                .disabled(sending || annotations.capturing)
                        } else {
                            Text("Start an agent in this workspace to send feedback.").font(Theme.captionFont).foregroundStyle(Theme.textSecondary)
                        }
                    }
                }
            }.padding(10).foregroundStyle(Theme.textPrimary).background(Theme.chrome)
                .popover(isPresented: Binding(get: { preview != nil }, set: { if !$0 { preview = nil } })) {
                    if let preview, let image = NSImage(data: preview) {
                        Image(nsImage: image).resizable().scaledToFit().frame(width: 500, height: 320).padding(10)
                    }
                }
        }
    }

    private func send() {
        guard !sending, !annotations.items.isEmpty else { return }
        let batch = annotations.items
        let sentIds = Set(batch.map(\.id))
        let prompt = BrowserAnnotation.prompt(batch)
        if target.hasPrefix("chat:"), let session = sessions.first(where: { "chat:" + $0.id == target }) {
            let images = batch.compactMap { $0.screenshot.flatMap(NSImage.init(data:)).flatMap(AgentSession.Attachment.init(image:)) }
            session.send(prompt, attachments: images)
            annotations.items.removeAll { sentIds.contains($0.id) }
            ToastCenter.shared.succeed(nil, "Sent browser annotations", detail: session.title)
            return
        }
        guard let agent = agents.first(where: { "pane:" + $0.paneId == target }) else { return }
        sending = true
        let client = window.store.client
        let name = DiffReviewView.name(agent, in: window.store)
        Task {
            do {
                let failed = try await Task.detached(priority: .userInitiated) {
                    // CLI agents read explicit image paths; native conversations receive image attachments.
                    let folder = EngineSession.supportDirectory.appendingPathComponent("browser-captures/" + UUID().uuidString)
                    try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
                    var text = prompt
                    for (index, item) in batch.enumerated() {
                        if let data = item.screenshot {
                            let url = folder.appendingPathComponent("element-\(index + 1).png")
                            try data.write(to: url, options: .atomic)
                            try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
                            text += "\nScreenshot \(index + 1): \(url.path)"
                        }
                    }
                    // Never fall back to typing page content into a shell if the agent exited.
                    _ = try client.call("agent.prompt", ["target": agent.paneId, "text": text])
                    return [String]()
                }.value
                if failed.isEmpty {
                    annotations.items.removeAll { sentIds.contains($0.id) }
                    annotations.failure = nil
                    ToastCenter.shared.succeed(nil, "Sent browser annotations", detail: name)
                } else { annotations.failure = "Couldn't send to \(name). Your annotations are still here." }
            } catch { annotations.failure = error.localizedDescription }
            sending = false
        }
    }
}
