import AppKit
import SwiftUI

/// Colours a tab or workspace can be given by hand. Stored by name, so the
/// shades can be retuned without losing anyone's choices. Each is bright
/// enough to read as a wash over dark chrome and deep enough to hold its hue
/// over light.
enum TabColor: String, CaseIterable, Identifiable {
    case red, orange, yellow, green, teal, blue, purple, pink

    var id: String { rawValue }

    var hex: String {
        switch self {
        case .red: "E5484D"
        case .orange: "F76B15"
        case .yellow: "F5B83D"
        case .green: "30A46C"
        case .teal: "12A5A0"
        case .blue: "3B82F6"
        case .purple: "8E4EC6"
        case .pink: "D6409F"
        }
    }

    var name: String { rawValue.capitalized }
    var color: Color { Color(hex: hex) }

    /// A filled dot for menus. Drawn rather than a symbol, since menus
    /// flatten template images to the text colour.
    var swatch: NSImage {
        let size = NSSize(width: 16, height: 16)
        let image = NSImage(size: size, flipped: false) { rect in
            let dot = rect.insetBy(dx: 1, dy: 1)
            (NSColor(hex: hex) ?? .gray).setFill()
            NSBezierPath(ovalIn: dot).fill()
            NSColor.black.withAlphaComponent(0.18).setStroke()
            let rim = NSBezierPath(ovalIn: dot.insetBy(dx: 0.5, dy: 0.5))
            rim.lineWidth = 1
            rim.stroke()
            return true
        }
        image.isTemplate = false
        image.accessibilityDescription = name
        return image
    }
}

/// A row of colour dots for a context menu, like Finder's tags: the slashed
/// circle clears the colour.
struct TabColorPicker: View {
    let title: String
    @Binding var selection: TabColor?

    var body: some View {
        Picker(title, selection: $selection) {
            Label("None", systemImage: "circle.slash")
                .tag(TabColor?.none)
            ForEach(TabColor.allCases) { color in
                Label { Text(color.name) } icon: { Image(nsImage: color.swatch) }
                    .tag(TabColor?.some(color))
            }
        }
        .pickerStyle(.palette)
    }
}
