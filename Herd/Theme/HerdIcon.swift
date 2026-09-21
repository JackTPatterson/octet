import SwiftUI

/// Every icon in Herd, drawn from the iconsax linear set bundled in
/// Assets.xcassets/Icons (see scripts/import-icons.py). Call sites and data
/// tables name icons by a stable key; this table picks the artwork.
struct HerdIcon: View {
    let name: String
    var size: CGFloat = 14

    init(_ name: String, size: CGFloat = 14) {
        self.name = name
        self.size = size
    }

    struct Art {
        let asset: String
        /// Degrees; the set has no plain "x", so close is a rotated plus.
        var rotation: Double = 0
        /// The iconsax style: "linear" by default, "bold" for filled marks.
        var style = "linear"
        init(_ asset: String, rotation: Double = 0, style: String = "linear") {
            self.asset = asset
            self.rotation = rotation
            self.style = style
        }

        /// The asset catalog name; other styles carry a suffix.
        var assetName: String { style == "linear" ? asset : "\(asset)-\(style)" }
    }

    static let map: [String: Art] = [
        "xmark": .init("add", rotation: 45),
        "xmark.bin": .init("trash"),
        "xmark.bin.fill": .init("trash"),
        "xmark.octagon": .init("close-circle"),
        "xmark.circle.fill": .init("close-circle"),
        "trash": .init("trash"),
        "paperclip": .init("paperclip"),
        "tool.read": .init("document-text"),
        "tool.edit": .init("edit-2"),
        "tool.write": .init("document-normal"),
        "tool.search": .init("search-normal"),
        "tool.web": .init("global-search"),
        "tool.fetch": .init("global"),
        "tool.run": .init("code-1"),
        "tool.agent": .init("profile-2user"),
        "tool.todo": .init("task-square"),
        "tool.mcp": .init("share"),
        "tool.notebook": .init("note-2"),
        "tool.other": .init("hierarchy-3"),
        "tool.todo.done": .init("tick-square"),
        "tool.todo.open": .init("stop"),
        "tool.todo.active": .init("timer-start"),
        "pencil": .init("edit"),
        "safari": .init("global"),
        "xmark.rectangle": .init("close-square"),
        "xmark.square": .init("close-square"),
        "plus": .init("add"),
        "plus.square": .init("add-square"),
        "rectangle.stack.badge.plus": .init("add-square"),
        "minus": .init("minus"),
        "magnifyingglass": .init("search-normal"),
        "doc.text.magnifyingglass": .init("search-status"),
        "sparkle.magnifyingglass": .init("search-status"),
        "terminal": .init("code-1"),
        "sidebar.left": .init("sidebar-left"),
        "chevron.down": .init("arrow-down-02"),
        "chevron.left": .init("arrow-left-02"),
        "chevron.right": .init("arrow-right-02"),
        "chevron.down.square": .init("arrow-square-down"),
        "chevron.up.square": .init("arrow-square-up"),
        "arrow.down": .init("arrow-down-01"),
        "arrow.up": .init("arrow-up-01"),
        "arrow.left": .init("arrow-left-01"),
        "arrow.right": .init("arrow-right-01"),
        "arrow.left.square": .init("arrow-square-left"),
        "arrow.right.square": .init("arrow-square-right"),
        "arrow.left.to.line": .init("arrow-square-left"),
        "arrow.right.to.line": .init("arrow-square-right"),
        "arrow.clockwise": .init("rotate-right"),
        "arrow.counterclockwise.circle": .init("refresh-circle"),
        "arrow.counterclockwise.circle.fill": .init("refresh-circle"),
        "clock.arrow.circlepath": .init("clock"),
        "clock": .init("clock"),
        "arrow.up.left.and.arrow.down.right": .init("maximize-4"),
        "arrow.triangle.branch": .init("hierarchy-3"),
        // The set's "check" is a text cursor, not a tick.
        // Check circles are filled everywhere.
        "checkmark": .init("tick-circle", style: "bold"),
        "checkmark.circle": .init("tick-circle", style: "bold"),
        "checkmark.circle.fill": .init("tick-circle", style: "bold"),
        "checkmark.square.fill": .init("tick-square"),
        "square": .init("stop"),
        "exclamationmark.triangle.fill": .init("danger"),
        "info.circle.fill": .init("info-circle"),
        "doc.on.doc": .init("copy"),
        "doc": .init("document"),
        "folder": .init("folder"),
        "folder.fill": .init("folder"),
        "folder.badge.plus": .init("folder-add"),
        "folder.badge.gearshape": .init("folder-2"),
        "gearshape": .init("setting-2"),
        "slider.horizontal.3": .init("setting-4"),
        "paintpalette": .init("brush"),
        "keyboard": .init("keyboard"),
        "lightbulb": .init("lamp-charge"),
        "sparkle": .init("magic-star"),
        "sparkles": .init("magic-star"),
        "pin": .init("bookmark"),
        "pin.fill": .init("bookmark"),
        "pin.slash": .init("bookmark-2"),
        "pause.circle": .init("pause-circle"),
        "play.circle": .init("play-circle"),
        "pencil.line": .init("edit-2"),
        "link.badge.plus": .init("link-2"),
        "list.bullet.rectangle": .init("task-square"),
        "moon.zzz": .init("moon"),
        "point.3.connected.trianglepath.dotted": .init("share"),
        "puzzlepiece.extension": .init("main-component"),
        "rectangle.on.rectangle": .init("cards"),
        "rectangle.split.1x2": .init("row-vertical"),
        "rectangle.split.2x1": .init("row-horizontal"),
        "square.and.arrow.down": .init("receive-square-01"),
        "square.and.arrow.down.on.square": .init("document-download"),
        "square.stack.3d.up": .init("layer"),
        "text.bubble": .init("message-text"),
        "graduationcap": .init("teacher"),
    ]

    var body: some View {
        let art = Self.map[name] ?? .init("more")
        Image("Icons/" + art.assetName)
            .renderingMode(.template)
            .resizable()
            .interpolation(.high)
            .frame(width: size, height: size)
            .rotationEffect(.degrees(art.rotation))
            .accessibilityHidden(true)
    }
}
