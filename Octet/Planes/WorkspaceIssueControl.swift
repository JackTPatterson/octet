import SwiftUI

struct WorkspaceIssueControl: View {
    let directory: String?
    @State private var link: WorkspaceIssueLink?
    var body: some View {
        Group {
            if let link {
                OctetIconButton(icon: "link", help: "\(link.key): \(link.title)") {
                    if let url = link.url, ["https", "http"].contains(url.scheme ?? "") { NSWorkspace.shared.open(url) }
                }
            }
        }.task(id: directory) {
            guard let directory else { link = nil; return }
            link = await Task.detached { try? WorkspaceIssueLink.read(in: directory) }.value
        }
    }
}
