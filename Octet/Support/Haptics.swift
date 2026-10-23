import AppKit

/// Light trackpad feedback for moments that are physical: crossing a tick
/// on a rail, snapping to a width, a command becoming runnable. The system
/// plays it only on a Force Touch trackpad with the setting on, and does
/// nothing elsewhere, so callers needn't check.
enum Haptics {
    /// Passing over a detent: a tick on the minimap, a snap point.
    @MainActor static func tick() {
        NSHapticFeedbackManager.defaultPerformer.perform(.alignment, performanceTime: .now)
    }

    /// Crossing into a new state: a little firmer than a tick.
    @MainActor static func step() {
        NSHapticFeedbackManager.defaultPerformer.perform(.levelChange, performanceTime: .now)
    }
}
