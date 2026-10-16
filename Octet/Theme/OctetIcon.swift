import SwiftUI

/// Every icon in Octet, drawn from the iconsax linear set bundled in
/// Assets.xcassets/Icons (see scripts/import-icons.py). Call sites and data
/// tables name icons by a stable key; this table picks the artwork.
struct OctetIcon: View {
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
        /// An SF Symbol drawn instead, for marks the bundled set lacks.
        var symbol: String?
        /// A mark Octet draws itself, in the set's line weight.
        var glyph: OctetGlyph.Kind?
        /// Drawn flipped left to right, e.g. the sidebar mark for the right.
        var mirrored = false
        init(_ asset: String, rotation: Double = 0, style: String = "linear", mirrored: Bool = false) {
            self.asset = asset
            self.rotation = rotation
            self.style = style
            self.mirrored = mirrored
        }

        static func glyph(_ kind: OctetGlyph.Kind) -> Art {
            var art = Art("more")
            art.glyph = kind
            return art
        }

        /// An SF Symbol stand-in until the iconsax mark is imported.
        static func symbol(_ name: String) -> Art {
            var art = Art("more")
            art.symbol = name
            return art
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
        "eye": .init("eye"),
        "tool.todo.done": .init("tick-square"),
        "tool.todo.open": .init("stop"),
        "tool.todo.active": .init("timer-start"),
        "pencil": .init("edit"),
        "safari": .init("global"),
        // iconsax's "cloud" isn't imported yet; the globe stands in.
        "cloud": .init("global"),
        "remote": .init("global"),
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
        "arrow.uturn.backward": .init("rotate-right"),
        /// T3 Code's rotate-ccw: Restore Defaults.
        "rotate.ccw": .init("rotate-right", mirrored: true),
        /// T3 Code's undo-2: a row's Reset to Default.
        "undo": .symbol("arrow.uturn.backward"),
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
        // Planes and pull requests. SF Symbols stand in where the bundled
        // iconsax set has no mark (scripts/import-icons.py needs its source).
        "sidebar.right": .init("sidebar-left", mirrored: true),
        "panel.bottom": .symbol("rectangle.bottomthird.inset.filled"),
        "arrow.down.right.and.arrow.up.left": .symbol("arrow.down.right.and.arrow.up.left"),
        "pull.request": .glyph(.pullRequest),
        "merge": .glyph(.merge),
        "branch": .init("hierarchy-3"),
        "commit": .glyph(.commit),
        "tag": .symbol("tag"),
        "person.badge.plus": .symbol("person.badge.plus"),
        "person.2": .init("profile-2user"),
        "arrow.up.right": .symbol("arrow.up.right"),
        "doc.diff": .symbol("plus.forwardslash.minus"),
        "message": .init("message-text"),
        // Flat, filled dots, not the set's triangle of three.
        "ellipsis": .symbol("ellipsis"),
        "check": .symbol("checkmark"),
        "circle.check": .symbol("checkmark.circle"),
        "circle.x": .symbol("xmark.circle"),
        "circle.dot": .symbol("circle.dotted"),
        "list": .symbol("list.bullet"),
        "iphone": .symbol("iphone"),
        "lock": .symbol("lock"),
        "menucard": .symbol("menucard"),
        "pilcrow": .symbol("paragraphsign"),
        "eye.slash": .symbol("eye.slash"),
        // The Device plane. Prefixed so they can't collide with keys other
        // planes add; SF Symbols until iconsax marks are imported.
        "device.iphone": .symbol("iphone"),
        "device.ipad": .symbol("ipad"),
        "device.android": .symbol("candybarphone"),
        "device.home": .symbol("house"),
        "device.lock": .symbol("lock"),
        "device.camera": .symbol("camera"),
        "device.sun": .symbol("sun.max"),
        "device.moon": .symbol("moon"),
        "device.location": .symbol("location"),
        "device.textsize": .symbol("textformat.size"),
        "device.tools": .symbol("wrench.and.screwdriver"),
        "device.power": .symbol("power"),
        "device.back": .symbol("arrow.uturn.backward"),
        "device.recents": .symbol("square.on.square"),
        "device.rotate": .symbol("rotate.right"),
        "device.send": .symbol("paperplane"),
    ]

    var body: some View {
        let art = Self.map[name] ?? .symbol("ellipsis")
        Group {
            if let glyph = art.glyph {
                OctetGlyph(kind: glyph)
                    .stroke(style: StrokeStyle(lineWidth: max(1.1, size / 10.5), lineCap: .round, lineJoin: .round))
                    .frame(width: size, height: size)
            } else if let symbol = art.symbol {
                Image(systemName: symbol)
                    .font(.system(size: size * 0.86, weight: .regular))
                    .frame(width: size, height: size)
            } else {
                Image("Icons/" + art.assetName)
                    .renderingMode(.template)
                    .resizable()
                    .interpolation(.high)
                    .frame(width: size, height: size)
            }
        }
        .scaleEffect(x: art.mirrored ? -1 : 1, y: 1)
        .rotationEffect(.degrees(art.rotation))
        .accessibilityHidden(true)
    }
}

/// Git marks the bundled set lacks, drawn on a 24-point grid in the set's
/// line style: two rings joined by the path a change takes.
struct OctetGlyph: Shape {
    enum Kind { case pullRequest, merge, commit }
    let kind: Kind

    func path(in rect: CGRect) -> Path {
        let scale = min(rect.width, rect.height) / 24
        func point(_ x: CGFloat, _ y: CGFloat) -> CGPoint {
            CGPoint(x: rect.minX + x * scale, y: rect.minY + y * scale)
        }
        func ring(_ path: inout Path, _ x: CGFloat, _ y: CGFloat) {
            path.addEllipse(in: CGRect(x: rect.minX + (x - 2.6) * scale, y: rect.minY + (y - 2.6) * scale,
                                       width: 5.2 * scale, height: 5.2 * scale))
        }
        var path = Path()
        switch kind {
        case .pullRequest:
            ring(&path, 6, 5.5)
            ring(&path, 18, 18.5)
            path.move(to: point(6, 8.1)); path.addLine(to: point(6, 21))
            path.move(to: point(18, 15.9)); path.addLine(to: point(18, 9.5))
            path.addQuadCurve(to: point(15.5, 6.5), control: point(18, 6.5))
            path.addLine(to: point(12, 6.5))
            path.move(to: point(14, 4.3)); path.addLine(to: point(11.8, 6.5)); path.addLine(to: point(14, 8.7))
        case .merge:
            ring(&path, 6, 5.5)
            ring(&path, 18, 17.5)
            path.move(to: point(6, 8.1)); path.addLine(to: point(6, 21))
            path.move(to: point(6, 9.5))
            path.addQuadCurve(to: point(15.4, 17.5), control: point(7, 17.5))
        case .commit:
            ring(&path, 12, 12)
            path.move(to: point(2.5, 12)); path.addLine(to: point(9.4, 12))
            path.move(to: point(14.6, 12)); path.addLine(to: point(21.5, 12))
        }
        return path
    }
}
