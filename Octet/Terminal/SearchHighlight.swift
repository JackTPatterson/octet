import SwiftUI

/// The find match shown in the terminal, boxed where it sits, since the
/// session server's search doesn't select it on screen.
@MainActor
final class SearchHighlight: ObservableObject {
    static let shared = SearchHighlight()

    struct Box: Equatable {
        let paneId: String
        /// Row in the pane's view, from the top.
        let row: Int
        let startColumn: Int
        /// The last column, when the match ends on the same row.
        let endColumn: Int?
    }

    @Published var box: Box?
}

struct SearchHighlightView: View {
    @ObservedObject var highlight = SearchHighlight.shared
    let layout: EngineLayout?
    /// Where the grid's first row is drawn.
    let contentTop: CGFloat
    /// The real cell size, when known; else worked out from the layout.
    var cellSize: CGSize = .zero
    var contentLeft: CGFloat = 0

    var body: some View {
        GeometryReader { proxy in
            if let box = highlight.box, let pane = layout?.panes.first(where: { $0.paneId == box.paneId }),
               let frame = layout?.frame(ofPane: box.paneId, in: proxy.size), pane.rect.width > 0, pane.rect.height > 0,
               (0..<pane.rect.height).contains(box.row) {
                let cellWidth = cellSize.width > 0 ? cellSize.width : frame.width / CGFloat(pane.rect.width)
                let cellHeight = cellSize.height > 0 ? cellSize.height : frame.height / CGFloat(pane.rect.height)
                let shift = contentTop
                let columns = max(1, (box.endColumn ?? pane.rect.width - 1) - box.startColumn + 1)
                RoundedRectangle(cornerRadius: 2)
                    .fill(Theme.accent.opacity(0.28))
                    .overlay(RoundedRectangle(cornerRadius: 2).strokeBorder(Theme.accent, lineWidth: 1.5))
                    .frame(width: CGFloat(columns) * cellWidth + 4, height: cellHeight + 2)
                    .offset(x: CGFloat(pane.rect.x) * cellWidth + contentLeft + CGFloat(box.startColumn) * cellWidth - 2,
                            y: shift + CGFloat(pane.rect.y + box.row) * cellHeight - 1)
                    .allowsHitTesting(false)
                    .onAppear { DebugSnapshot.overlay("search-highlight", true) }
                    .onDisappear { DebugSnapshot.overlay("search-highlight", false) }
            }
        }
        .allowsHitTesting(false)
    }
}
