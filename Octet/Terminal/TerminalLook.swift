import SwiftUI

/// How the terminal itself draws, for Octet's views that sit on its grid or
/// name what's in it (the command line, hint labels), so they look like
/// part of the terminal rather than chrome laid over it.
enum TerminalLook {
    /// The terminal's font from Settings › Text; empty there is the system
    /// monospaced font. `size` defaults to the terminal's own.
    @MainActor
    static func font(size: CGFloat? = nil, weight: Font.Weight = .regular) -> Font {
        let values = SettingsStore.shared.values
        let size = size ?? values.fontSize
        return values.fontFamily.isEmpty
            ? .system(size: size, weight: weight, design: .monospaced)
            : .custom(values.fontFamily, fixedSize: size).weight(weight)
    }

    /// The terminal's cursor: the renderer is given no cursor colour of its
    /// own, so it draws in the default text colour (see `rendererConfig`).
    static var cursorColor: Color { Theme.isLight ? .black : .white }
}
