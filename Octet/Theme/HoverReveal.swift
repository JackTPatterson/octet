import SwiftUI

/// A quiet control that fades in with the pointer, and also while it has
/// keyboard focus: with keyboard navigation on, Tab lands on it and it
/// shows, instead of focusing something invisible.
struct HoverReveal: ViewModifier {
    let shown: Bool
    @FocusState private var focused: Bool

    func body(content: Content) -> some View {
        content
            .focused($focused)
            .opacity(shown || focused ? 1 : 0)
    }
}

extension View {
    /// Shown while `shown` (the row is hovered) or while focused. Apply it
    /// to each control, not a group of them, so focus reveals the one it's on.
    func hoverReveal(_ shown: Bool) -> some View {
        modifier(HoverReveal(shown: shown))
    }
}
