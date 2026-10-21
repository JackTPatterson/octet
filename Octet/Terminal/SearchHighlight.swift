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
    @ObservedObject var geometry: PaneGeometry

    var body: some View {
        GeometryReader { _ in
            if let box = highlight.box, let pane = geometry.panes[box.paneId], (0..<pane.rows).contains(box.row) {
                let columns = max(1, (box.endColumn ?? pane.columns - 1) - box.startColumn + 1)
                let origin = pane.origin(row: box.row, column: box.startColumn)
                RoundedRectangle(cornerRadius: 2)
                    .fill(Theme.accent.opacity(0.28))
                    .overlay(RoundedRectangle(cornerRadius: 2).strokeBorder(Theme.accent, lineWidth: 1.5))
                    .frame(width: CGFloat(columns) * pane.cellSize.width + 4, height: pane.cellSize.height + 2)
                    .offset(x: origin.x - 2, y: origin.y - 1)
                    .allowsHitTesting(false)
                    .onAppear { DebugSnapshot.overlay("search-highlight", true) }
                    .onDisappear { DebugSnapshot.overlay("search-highlight", false) }
            }
        }
        .allowsHitTesting(false)
    }
}
